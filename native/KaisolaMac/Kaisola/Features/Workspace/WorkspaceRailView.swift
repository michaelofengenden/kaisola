import AppKit
import Darwin
import SwiftUI

/// Header actions that may collapse into the "…" menu at narrow widths.
/// Hiding the panel is deliberately not among them: every hideable surface
/// answers from its own visible minus (the pane-header grammar), and at the
/// default rail width the hide control used to vanish into the overflow menu
/// and read as missing.
enum WorkspaceRailHeaderAction: String, CaseIterable, Hashable, Sendable {
    case newFile
    case newFolder
    case followAgentFiles
    case refresh
}

struct WorkspaceRailHeaderLayout: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case compact
        case regular
    }

    static let regularMinimumWidth: CGFloat = 236

    /// The compact header's width budget, named so it is a testable contract
    /// rather than a pile of literals: the responsive shell may compress the
    /// rail to 150pt, and the row must still fit its four fixed pieces plus
    /// the search field's floor. The mutation spinner borrows the magnifier's
    /// slot instead of adding a fifth piece, which is what used to blow the
    /// budget mid-operation.
    static let itemSpacing: CGFloat = 5
    static let glyphWidth: CGFloat = 16
    static let controlWidth: CGFloat = 20
    static let searchMinimumWidth: CGFloat = 46
    static let capsulePadding: CGFloat = 6
    static let outerPadding: CGFloat = 6

    static var minimumCompactHeaderWidth: CGFloat {
        outerPadding * 2 + capsulePadding * 2
            + glyphWidth + searchMinimumWidth + controlWidth * 2
            + itemSpacing * 3
    }

    let mode: Mode
    let searchPlaceholder: String
    let overflowActions: [WorkspaceRailHeaderAction]

    static func resolve(availableWidth: CGFloat) -> WorkspaceRailHeaderLayout {
        guard availableWidth >= regularMinimumWidth else {
            return WorkspaceRailHeaderLayout(
                mode: .compact,
                searchPlaceholder: "Search",
                overflowActions: WorkspaceRailHeaderAction.allCases
            )
        }
        return WorkspaceRailHeaderLayout(
            mode: .regular,
            searchPlaceholder: "Search files",
            overflowActions: []
        )
    }
}

/// One source of truth for what a file-tree row says and does through either
/// Full Keyboard Access or VoiceOver. The visible indentation and glyphs are
/// presentation only; role, hierarchy, disclosure, and selection live here.
struct WorkspaceFileTreeRowAccessibility: Equatable, Sendable {
    enum Activation: Equatable, Sendable {
        case openFile
        case expandFolder
        case collapseFolder
    }

    let label: String
    let value: String
    let hint: String
    let activation: Activation
    let disclosureActionLabel: String?
    let isSelected: Bool

    init(
        name: String,
        isDirectory: Bool,
        depth: Int,
        isExpanded: Bool,
        isSelected: Bool
    ) {
        let level = max(0, depth) + 1
        self.label = name
        self.isSelected = isSelected
        if isDirectory {
            let expansion = isExpanded ? "expanded" : "collapsed"
            self.value = "Folder, level \(level), \(expansion), \(isSelected ? "selected" : "not selected")"
            self.hint = isExpanded
                ? "Activate to collapse this folder"
                : "Activate to expand this folder"
            self.activation = isExpanded ? .collapseFolder : .expandFolder
            self.disclosureActionLabel = isExpanded ? "Collapse" : "Expand"
        } else {
            self.value = "File, level \(level), \(isSelected ? "selected" : "not selected")"
            self.hint = "Activate to open this file"
            self.activation = .openFile
            self.disclosureActionLabel = nil
        }
    }

    /// A focused Button and VoiceOver's default Activate gesture take the same
    /// route; this name makes the keyboard contract explicit in tests.
    var keyboardActivation: Activation { activation }

    /// Folders additionally advertise a named Expand/Collapse action. Files
    /// use the Button's ordinary Activate action and expose no fake disclosure.
    var voiceOverDisclosureAction: Activation? {
        disclosureActionLabel == nil ? nil : activation
    }
}

private struct WorkspaceFileTreeAccessibilityModifier: ViewModifier {
    let descriptor: WorkspaceFileTreeRowAccessibility
    let performDisclosure: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        let described = content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(descriptor.label)
            .accessibilityValue(descriptor.value)
            .accessibilityHint(descriptor.hint)
            .accessibilityAddTraits(
                descriptor.isSelected ? [.isButton, .isSelected] : .isButton
            )
        if let actionLabel = descriptor.disclosureActionLabel {
            described.accessibilityAction(named: Text(actionLabel)) {
                performDisclosure()
            }
        } else {
            described
        }
    }
}

/// The workspace rail: a lazy file tree for the active project (⌘B). Clicking a
/// file opens it in the preview pane.
/// The Files rail's row grammar, shared with the sidebar it faces.
///
/// The two rails frame the workspace as one pane of glass each, but their rows
/// used to select in two dialects — the sidebar's designed accent pill against
/// an ad-hoc flat wash here: two corner radii, and one appearance-blind opacity
/// that all but vanished on the dark rail. The 2026-08-26 panel review against
/// the Safari sidebar and Apple's Landmarks sample made it one grammar: the
/// rail borrows the sidebar's own pill constants, so a selected file and a
/// selected chat are the same statement on opposite edges of the window.
enum WorkspaceRailRowGrammar {
    /// The sidebar's pill radius, verbatim.
    static var selectionCornerRadius: CGFloat { QuietSelectionPill.cornerRadius }
    /// The sidebar's appearance-aware selection coverage, verbatim.
    static func selectionFillOpacity(dark: Bool) -> Double {
        QuietSelectionPill.fillOpacity(dark: dark)
    }
    /// Safari-spaced rows: 4.5pt of air packs a tree row to ≈25pt, between the
    /// sidebar's 26pt session rows and the old 21pt cram — and keeps the shared
    /// pill radius under the documented lozenge ratio on the rail's own rows.
    static let rowVerticalPadding: CGFloat = 4.5
}

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
    @Environment(\.colorScheme) private var colorScheme
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
    @State private var searchText = {
        let environment = ProcessInfo.processInfo.environment
        return environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1"
            && environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "workspace-search-partial"
            ? "indexed-fixture"
            : ""
    }()
    @State private var renameTarget: FileNode?
    @State private var renameDraft = ""
    @State private var moveTarget: FileNode?
    @State private var creationRequest: CreationRequest?
    @State private var creationDraft = ""
    @State private var trashTarget: FileNode?
    @State private var instructionFileFailure: WorkspaceInstructionFile.Failure?
    @State private var isMutating = false
    /// Which row the pointer is over, and which row the keyboard is on. Either
    /// one earns that row its "⋯" button; every other row keeps it transparent.
    @State private var hoveredRow: String?
    @FocusState private var focusedRow: String?
    /// Sticky fallback for inputs that cannot hover — see `WorkspaceRowActions`.
    @State private var rowActionsAlwaysVisible = false
    /// Live FSEvents watcher — agent writes refresh the tree automatically.
    @StateObject private var watcher: WorkspaceWatcher
    @StateObject private var tree: WorkspaceTreeModel
    /// Keeps one click and two clicks from both opening the same file.
    @StateObject private var clicks = WorkspaceRowClickArbiter()

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
            workspaceHeader

            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !tree.isSearching {
                partialSearchNotice
            }

            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let emptyState = tree.emptyState(for: root) {
                    projectEmptyState(emptyState)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            nodeRows(for: root, depth: 0)
                        }
                        .padding(.vertical, 6)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            } else if tree.isSearching {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Indexing files…").font(.caption).foregroundStyle(.kaisolaSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tree.searchResults.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(tree.searchResults, id: \.self) { path in
                            let node = FileNode(
                                url: root.appendingPathComponent(path).standardizedFileURL,
                                isDirectory: false
                            )
                            Button {
                                openFile(node.url, false)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "doc.text")
                                        .font(.caption)
                                        .foregroundStyle(
                                            isSelected(node) ? QuietSelectionPill.ink : Color.kaisolaSecondary
                                        )
                                    fileName(path, selected: isSelected(node))
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, WorkspaceRailRowGrammar.rowVerticalPadding)
                                .padding(.trailing, Self.optionsClearance - 10)
                                .background(
                                    isSelected(node)
                                        ? Color.accentColor.opacity(
                                            WorkspaceRailRowGrammar.selectionFillOpacity(dark: colorScheme == .dark)
                                        )
                                        : .clear,
                                    in: ShellTabShape.shape(
                                        cornerRadius: WorkspaceRailRowGrammar.selectionCornerRadius
                                    )
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(path)
                            .focused($focusedRow, equals: node.id)
                            .contextMenu {
                                itemActions(node)
                            }
                            .overlay(alignment: .trailing) {
                                itemMenu(node, revealed: revealsRowActions(node))
                                    .padding(.trailing, 6)
                            }
                            .onHover { inside in setRowHover(node, inside) }
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
        // One flush full-height column, exactly like the left project rail —
        // and, graduated 2026-08-28, the same SURFACE as the canvas: the rail
        // mounts the canvas recipe (`WorkspaceBackdropView`), not the
        // dedicated rail wash, so the boundary to the content carries no tone
        // jump and the resize divider's hairline is the whole seam.
        .background {
            WorkspaceBackdropView(mode: settings.workspaceBackdrop)
                .ignoresSafeArea()
        }
        .task {
            tree.load(root)
            tree.search(searchText)
            revealSelection()
            rowActionsAlwaysVisible = WorkspaceRowActions.systemAlwaysVisible()
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
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            rowActionsAlwaysVisible = WorkspaceRowActions.systemAlwaysVisible()
        }
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
            Button("New AGENTS.md") { createInstructionFile() }
                .disabled(isMutating)
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
                await performMove(target, to: destinationDirectory)
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
        .alert(
            "Couldn't Create \(WorkspaceInstructionFile.fileName)",
            isPresented: instructionFileFailurePresented,
            presenting: instructionFileFailure
        ) { _ in
            // The alert writes `isPresented` back *after* this action returns,
            // so a synchronous retry's new failure would be cleared before it
            // could be shown. Retry on the next turn instead.
            Button("Try Again") { Task { @MainActor in createInstructionFile() } }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("workspace-agents-create-retry")
            Button("Cancel", role: .cancel) { instructionFileFailure = nil }
        } message: { failure in
            Text(failure.message)
        }
        .accessibilityLabel("Project files")
    }

    private var workspaceHeader: some View {
        GeometryReader { geometry in
            let layout = WorkspaceRailHeaderLayout.resolve(availableWidth: geometry.size.width)
            HStack(spacing: WorkspaceRailHeaderLayout.itemSpacing) {
                // A running mutation replaces the magnifier in its own slot;
                // an extra sibling used to push the row past the compressed
                // rail's width the moment anything was mutating.
                if isMutating {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: WorkspaceRailHeaderLayout.glyphWidth)
                        .accessibilityLabel("Updating project files")
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.kaisolaSecondary)
                        .frame(width: WorkspaceRailHeaderLayout.glyphWidth)
                }
                TextField(layout.searchPlaceholder, text: $searchText)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .frame(minWidth: WorkspaceRailHeaderLayout.searchMinimumWidth)
                    .layoutPriority(1)
                    .accessibilityLabel("Search files")
                if layout.mode == .compact {
                    compactHeaderMenu
                } else {
                    regularHeaderActions
                }
                hideRailButton
            }
            .padding(.horizontal, WorkspaceRailHeaderLayout.capsulePadding)
            .frame(height: 30)
            // A control surface, not a grey wash: Liquid Glass on macOS 26,
            // a light material below — either way the capsule reads white
            // over the rail's frost instead of a quaternary grey.
            .kaisolaControlSurface(interactive: false)
            .padding(.horizontal, WorkspaceRailHeaderLayout.outerPadding)
            .padding(.vertical, 6)
        }
        .frame(height: 42)
    }

    private var compactHeaderMenu: some View {
        Menu {
            Button("New File…") { beginCreate(.file, in: root) }
                .disabled(isMutating)
            Button("New Folder…") { beginCreate(.folder, in: root) }
                .disabled(isMutating)
            Divider()
            Button(followsAgentFiles ? "Stop Following Agent Files" : "Follow Agent Files") {
                followsAgentFiles.toggle()
            }
            .disabled(!canFollowAgentFiles)
            Button("Refresh Files") { refresh() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.semibold))
                .frame(width: WorkspaceRailHeaderLayout.controlWidth, height: 20)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("File actions")
        .accessibilityLabel("File actions")
    }

    private var regularHeaderActions: some View {
        HStack(spacing: 6) {
            Menu {
                Button("New File…") { beginCreate(.file, in: root) }
                    .disabled(isMutating)
                Button("New Folder…") { beginCreate(.folder, in: root) }
                    .disabled(isMutating)
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
                    .foregroundStyle(followsAgentFiles ? Color.accentColor : Color.kaisolaSecondary)
            }
            .buttonStyle(.borderless)
            .disabled(!canFollowAgentFiles)
            .help(canFollowAgentFiles
                ? (followsAgentFiles
                    ? "Stop following the selected agent's files"
                    : "Follow the selected agent's files")
                : "Select a Chat or Mesh to follow its files")
            .accessibilityLabel("Follow selected agent files")
            .accessibilityValue(followsAgentFiles ? "On" : "Off")
            Button(action: { refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Refresh files")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Always visible, whatever the rail width: the panel's own minus, in the
    /// same grammar as every session pane header.
    private var hideRailButton: some View {
        Button(action: close) {
            Image(systemName: "minus")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.kaisolaSecondary)
                .frame(width: WorkspaceRailHeaderLayout.controlWidth, height: 20)
        }
        .buttonStyle(.borderless)
        .help("Hide \(root.lastPathComponent) files (Command-B)")
        .accessibilityLabel("Hide Files")
        .accessibilityIdentifier("files.hide")
    }

    /// The index is deliberately bounded; when one of those bounds wins, do
    /// not let a partial match list masquerade as proof that another file does
    /// not exist. Folder browsing is the uncached scope escape hatch.
    @ViewBuilder
    private var partialSearchNotice: some View {
        if let notice = ProjectFileSearchPresentation.notice(for: tree.searchCompletion) {
            VStack(alignment: .leading, spacing: 5) {
                Label(notice.title, systemImage: "exclamationmark.magnifyingglass")
                    .font(.caption.weight(.semibold))
                Text(notice.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(notice.actionTitle) { searchText = "" }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.09))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(notice.title). \(notice.detail)")
            .accessibilityIdentifier("files.search-partial")
        }
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

    private var instructionFileFailurePresented: Binding<Bool> {
        Binding(
            get: { instructionFileFailure != nil },
            set: { if !$0 { instructionFileFailure = nil } }
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

    /// Asks the open editors whether this item may be changed. Returns the
    /// reason it may not, so a caller with a surface of its own — the Move
    /// sheet — can say it in place instead of behind a toast.
    @MainActor
    private func mutationBarrierRefusal(_ node: FileNode) -> String? {
        let request = WorkspaceFileMutationBarrierRequest(item: node.url)
        NotificationCenter.default.post(name: .kaisolaPrepareWorkspaceFileMutation, object: request)
        guard request.mayProceed else {
            return "Resolve the unsaved changes in \(node.name) before changing it."
        }
        return nil
    }

    @MainActor
    private func prepareMutation(_ node: FileNode) -> Bool {
        guard let refusal = mutationBarrierRefusal(node) else { return true }
        ToastCenter.shared.show(refusal, style: .error)
        return false
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

    /// Runs the move and reports what actually happened. This used to return
    /// `true` the moment it spawned its detached task, and the sheet read that
    /// as "done" and dismissed — so a failure arrived as a toast long after the
    /// destination the user picked had disappeared. The sheet now awaits this,
    /// which means a failure message stays the sheet's to show.
    @MainActor
    private func performMove(
        _ target: FileNode,
        to destinationDirectory: URL
    ) async -> WorkspaceMoveOutcome {
        if let refusal = mutationBarrierRefusal(target) { return .failed(refusal) }
        let destination = destinationDirectory.appendingPathComponent(
            target.name,
            isDirectory: target.isDirectory
        )
        let root = self.root
        isMutating = true
        defer { isMutating = false }
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
            return .succeeded
        } catch {
            return .failed(
                WorkspaceFileOperations.userFacingDescription(for: error, action: "move")
            )
        }
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

    /// Writes the starter AGENTS.md and opens it *only* once the write is
    /// confirmed. A suppressed error used to open a tab regardless, so a
    /// permission or disk failure left a phantom document that implied the
    /// instruction file was there. Failures now surface with a retry instead.
    private func createInstructionFile() {
        switch WorkspaceInstructionFile.create(in: root) {
        case let .success(outcome):
            if outcome.didWrite {
                ProjectFileIndex.shared.invalidate(root: root)
                tree.refresh(expandedDirectories: expanded.map { URL(fileURLWithPath: $0, isDirectory: true) })
            }
            instructionFileFailure = nil
            openFile(outcome.url, true)
        case let .failure(failure):
            instructionFileFailure = failure
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

    /// Compatibility surface retained for the original exclusive-create
    /// regression suite. The live action uses `WorkspaceInstructionFile`, whose
    /// low-level writer also rejects racing files and incomplete writes.
    static let agentsTemplate = WorkspaceInstructionFile.template

    @ViewBuilder
    private func nodeRows(for directory: URL, depth: Int) -> some View {
        if let nodes = tree.children(of: directory) {
            ForEach(nodes) { node in
                nodeRow(node, depth: depth)
                if node.isDirectory, expanded.contains(node.id) {
                    AnyView(nodeRows(for: node.url, depth: depth + 1))
                }
            }
            // A folder that is simply empty stays quiet. A folder Kaisola could
            // not read looks identical from here unless it says so, which is
            // how permission and I/O problems used to pass for empty ones.
            if let failure = tree.loadFailure(for: directory) {
                failureRow(failure, directory: directory, depth: depth)
            }
        } else {
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text("Loading…").font(.caption).foregroundStyle(.kaisolaTertiary)
            }
            .padding(.leading, CGFloat(depth) * 14 + 12)
            .padding(.vertical, 6)
            .task { tree.load(directory) }
        }
    }

    private func projectEmptyState(_ state: WorkspaceFilesEmptyState) -> some View {
        VStack(spacing: 12) {
            Spacer(minLength: 12)
            VStack(spacing: 8) {
                Image(systemName: state.systemImageName)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(state.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(state.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.title)
            .accessibilityValue(state.message)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(state.accessibilityIdentifier)
            VStack(spacing: 8) {
                Button(WorkspaceFilesEmptyState.newFileLabel) {
                    beginCreate(.file, in: root)
                }
                .accessibilityLabel("New File in project")
                .accessibilityIdentifier("files.empty.new-file")
                Button(WorkspaceFilesEmptyState.newFolderLabel) {
                    beginCreate(.folder, in: root)
                }
                .accessibilityLabel("New Folder in project")
                .accessibilityIdentifier("files.empty.new-folder")
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The one row a failed directory gets: what went wrong, and a way back.
    private func failureRow(
        _ failure: ProjectFiles.DirectoryLoadFailure,
        directory: URL,
        depth: Int
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(failure.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button("Retry") { tree.load(directory, force: true) }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityIdentifier("files.retry")
        }
        .padding(.leading, CGFloat(depth) * 14 + 12)
        .padding(.trailing, Self.optionsClearance - 10)
        .padding(.vertical, 4)
        .help(failure.diagnostic)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(failure.summary). \(failure.diagnostic)")
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
                clicks.click(rowID: node.id) { pinned in openFile(node.url, pinned) }
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
                    .foregroundStyle(
                        rowIsHighlighted(node)
                            ? QuietSelectionPill.ink
                            : (node.isDirectory ? Color.accentColor : .kaisolaSecondary)
                    )
                fileName(node.name, selected: rowIsHighlighted(node))
                Spacer(minLength: 0)
            }
            .padding(.vertical, WorkspaceRailRowGrammar.rowVerticalPadding)
            .padding(.leading, CGFloat(depth) * 14 + 10)
            // The options button is a trailing *overlay*, so it floats over
            // whatever the row draws. Without this the name ran under it and
            // its own "…" landed on the three dots, which at a zoomed text
            // size read as one smeared "⋯⋯". This is the button's 18pt plus
            // its 6pt inset, plus a little air.
            .padding(.trailing, Self.optionsClearance)
            .background(
                rowIsHighlighted(node)
                    ? Color.accentColor.opacity(
                        WorkspaceRailRowGrammar.selectionFillOpacity(dark: colorScheme == .dark)
                    )
                    : .clear,
                in: ShellTabShape.shape(
                    cornerRadius: WorkspaceRailRowGrammar.selectionCornerRadius
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(WorkspaceFileTreeAccessibilityModifier(
            descriptor: WorkspaceFileTreeRowAccessibility(
                name: node.name,
                isDirectory: node.isDirectory,
                depth: depth,
                isExpanded: expanded.contains(node.id),
                isSelected: !node.isDirectory
                    && selectedFile?.standardizedFileURL.path == node.url.standardizedFileURL.path
            ),
            performDisclosure: {
                guard node.isDirectory else { return }
                if expanded.contains(node.id) {
                    expanded.remove(node.id)
                } else {
                    expanded.insert(node.id)
                    tree.load(node.url)
                }
            }
        ))
        .accessibilityLabel(node.name)
        .id(node.id)
        .focused($focusedRow, equals: node.id)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard !node.isDirectory else { return }
                clicks.doubleClick(rowID: node.id) { pinned in openFile(node.url, pinned) }
            }
        )
        .contextMenu {
            itemActions(node)
        }
        .overlay(alignment: .trailing) {
            itemMenu(node, revealed: revealsRowActions(node))
                .padding(.trailing, 6)
        }
        .onHover { inside in setRowHover(node, inside) }
    }

    private func isSelected(_ node: FileNode) -> Bool {
        !node.isDirectory
            && selectedFile?.standardizedFileURL.path == node.url.standardizedFileURL.path
    }

    /// The pointer can only be over one row, but SwiftUI delivers the leave of
    /// the row it left after the enter of the row it reached, so a blind clear
    /// would erase the new row's hover.
    private func setRowHover(_ node: FileNode, _ inside: Bool) {
        if inside {
            hoveredRow = node.id
        } else if hoveredRow == node.id {
            hoveredRow = nil
        }
    }

    private func revealsRowActions(_ node: FileNode) -> Bool {
        WorkspaceRowActions.isRevealed(
            isHovering: hoveredRow == node.id,
            isFocused: focusedRow == node.id,
            isSelected: isSelected(node),
            alwaysVisible: rowActionsAlwaysVisible
        )
    }

    /// Room kept clear at the trailing edge for the floating options button.
    private static let optionsClearance: CGFloat = 30

    /// The selected file, or — while a click waits out the double-click window
    /// — the row that click will open. Without the second case a single click
    /// would leave the rail looking untouched until the document arrived.
    private func rowIsHighlighted(_ node: FileNode) -> Bool {
        guard !node.isDirectory else { return false }
        if let armedRowID = clicks.armedRowID { return armedRowID == node.id }
        return selectedFile?.standardizedFileURL.path == node.url.standardizedFileURL.path
    }

    /// A selected name speaks in the sidebar's voice: the accent-derived pill
    /// ink at semibold, exactly what a selected chat's title does across the
    /// window. Resting rows keep plain primary.
    private func fileName(_ name: String, selected: Bool = false) -> some View {
        FadingFileName(text: name, font: selected ? .callout.weight(.semibold) : .callout)
            .foregroundStyle(selected ? QuietSelectionPill.ink : Color.primary)
    }

    /// `revealed` drives opacity only. Dropping the menu from the hierarchy
    /// would take its accessibility label with it and leave VoiceOver nothing
    /// to land on, so a resting row keeps a fully described, fully hit-testable
    /// control that simply is not drawn.
    private func itemMenu(_ node: FileNode, revealed: Bool) -> some View {
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
        .opacity(revealed ? 1 : 0)
        .animation(.easeInOut(duration: KaisolaVisualSystem.stateDuration), value: revealed)
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

/// Decides what a click on a file row means, so a single click and a double
/// click stay mutually exclusive.
///
/// SwiftUI fires a row `Button` on every mouse-up and the two-tap gesture fires
/// on top of it, so one double click used to run the transient open twice and
/// then the pinned open: three navigations, a tab flickering between preview
/// and kept-open, and two preview loads for a document the user asked to keep.
/// Clicks land here instead. The transient open waits out one double-click
/// interval, and a second click inside that window cancels it and opens the
/// file pinned, so exactly one open leaves the rail per gesture.
///
/// The wait is only observable if the row looks dead while it runs, hence
/// `armedRowID`: the rail highlights the armed row immediately and the document
/// arrives a beat later.
@MainActor
final class WorkspaceRowClickArbiter: ObservableObject {
    /// The row whose transient open is waiting for a possible second click.
    @Published private(set) var armedRowID: String?

    /// The user's own double-click speed — never a longer wait than the window
    /// AppKit itself uses to call two clicks a double click.
    private let interval: @MainActor () -> TimeInterval
    private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    /// Monotonic ticket. Every armed open and every settled burst carries one so
    /// a timer that fires late can tell it was superseded.
    private var sequence = 0
    private var armedTicket = 0
    /// The row a double click already answered. Trailing clicks of the same
    /// burst — the button's second fire, a third click — are swallowed until
    /// the window closes.
    private var settledRowID: String?
    private var settledTicket = 0

    init(
        interval: @escaping @MainActor () -> TimeInterval = { NSEvent.doubleClickInterval },
        schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                work()
            }
        }
    ) {
        self.interval = interval
        self.schedule = schedule
    }

    /// One mouse-up on a file row. `open(true)` keeps the document open,
    /// `open(false)` opens it as the replaceable preview.
    func click(rowID: String, open: @escaping (Bool) -> Void) {
        if settledRowID == rowID { return }
        if armedRowID == rowID {
            settle(rowID: rowID, open: open)
        } else {
            arm(rowID: rowID, open: open)
        }
    }

    /// The two-tap gesture. Whether it arrives before or after the button's
    /// second fire is not guaranteed, so either one may settle the burst and
    /// the other is swallowed.
    func doubleClick(rowID: String, open: @escaping (Bool) -> Void) {
        guard settledRowID != rowID else { return }
        settle(rowID: rowID, open: open)
    }

    /// Clicking a second row before the window closes replaces the pending open
    /// rather than stacking two preview loads: the rail follows the last click.
    private func arm(rowID: String, open: @escaping (Bool) -> Void) {
        sequence += 1
        let ticket = sequence
        armedTicket = ticket
        armedRowID = rowID
        schedule(interval()) { [weak self] in
            guard let self, self.armedTicket == ticket else { return }
            self.armedRowID = nil
            open(false)
        }
    }

    private func settle(rowID: String, open: (Bool) -> Void) {
        sequence += 1
        let ticket = sequence
        if armedRowID == rowID {
            // Bumping the ticket is what cancels the armed transient open.
            armedTicket = ticket
            armedRowID = nil
        }
        settledTicket = ticket
        settledRowID = rowID
        schedule(interval()) { [weak self] in
            guard let self, self.settledTicket == ticket else { return }
            self.settledRowID = nil
        }
        open(true)
    }
}

/// What the Move sheet learns about an attempted move — the real result, not
/// the fact that the work started.
enum WorkspaceMoveOutcome: Equatable, Sendable {
    case succeeded
    case failed(String)
}

/// The Move sheet's own state: the destinations it found, the one the user
/// picked, and how far the attempt has gotten. It lives outside the view so the
/// rule that matters here — the sheet leaves only on a confirmed move — is a
/// thing that can be exercised without presenting a sheet.
@MainActor
final class WorkspaceMoveController: ObservableObject {
    enum Phase: Equatable {
        case choosing
        case moving
        case failed(String)
        case succeeded
    }

    let root: URL
    let item: FileNode

    @Published private(set) var directories: [URL] = []
    @Published private(set) var isLoading = true
    @Published private(set) var phase: Phase = .choosing
    @Published private(set) var selectedPath: String?
    @Published var searchText = ""

    init(root: URL, item: FileNode) {
        self.root = root
        self.item = item
    }

    var visibleDirectories: [URL] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return directories }
        return directories.filter {
            destinationLabel($0).localizedCaseInsensitiveContains(query)
        }
    }

    var selectedDirectory: URL? {
        guard let selectedPath else { return nil }
        return visibleDirectories.first { $0.path == selectedPath }
    }

    var isMoving: Bool { phase == .moving }

    /// Return and the Move button are inert until a row activation records an
    /// explicit choice. Loading and filtering never manufacture that choice.
    var canSubmit: Bool {
        !isLoading && !isMoving && !isFinished && selectedDirectory != nil
    }

    /// The full project-relative choice spoken after pointer or keyboard row
    /// activation. Read from the unfiltered directory set so changing search
    /// text cannot silently change (or rename) the user's choice.
    var selectionAnnouncement: String? {
        guard let selectedPath,
              let selected = directories.first(where: { $0.path == selectedPath }) else {
            return nil
        }
        return "Selected move destination: \(destinationLabel(selected))"
    }

    /// The one failure the user needs in front of them, shown in the sheet
    /// rather than in a toast behind it.
    var failureMessage: String? {
        guard case let .failed(message) = phase else { return nil }
        return message
    }

    /// The sheet's only permission to close itself.
    var isFinished: Bool { phase == .succeeded }

    func select(_ directory: URL) {
        let path = directory.standardizedFileURL.path
        guard !isMoving, visibleDirectories.contains(where: { $0.path == path }) else { return }
        selectedPath = path
        // The diagnostic described the previous destination.
        if case .failed = phase { phase = .choosing }
    }

    func loadDestinations() async {
        isLoading = true
        let root = root
        let movingItem = item.url
        let loaded = await Task.detached(priority: .utility) {
            ProjectFiles.moveDestinationDirectories(root: root, movingItem: movingItem)
        }.value
        guard !Task.isCancelled else { return }
        directories = loaded
        if let selectedPath, !loaded.contains(where: { $0.path == selectedPath }) {
            self.selectedPath = nil
        }
        isLoading = false
    }

    /// Awaits the move and records the result. The item and the destination are
    /// left exactly as they were on failure, so Retry is one more click rather
    /// than a rebuilt operation.
    func submit(_ move: @MainActor (URL) async -> WorkspaceMoveOutcome) async {
        guard !isMoving, !isFinished, let destination = selectedDirectory else { return }
        phase = .moving
        switch await move(destination) {
        case .succeeded:
            phase = .succeeded
        case let .failed(message):
            phase = .failed(message)
        }
    }

    func destinationLabel(_ directory: URL) -> String {
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

enum WorkspaceAgentsFileCreation {
    typealias Writer = (_ data: Data, _ target: URL) throws -> Void

    enum Failure: Error, Equatable, Sendable {
        case destinationExists
        case permissionDenied
        case diskFull
        case other

        var message: String {
            switch self {
            case .destinationExists:
                "AGENTS.md already exists. Rename or remove it, then try again."
            case .permissionDenied:
                "Kaisola doesn't have permission to create AGENTS.md in this project."
            case .diskFull:
                "There isn't enough disk space to create AGENTS.md."
            case .other:
                "Kaisola couldn't create AGENTS.md. Check the project and try again."
            }
        }
    }

    static func attempt(in root: URL, template: String) -> Result<URL, Failure> {
        attempt(in: root, template: template) { data, target in
            // Foundation rejects combining `.atomic` with
            // `.withoutOverwriting`. Exclusive creation is the required
            // boundary here: a racing AGENTS.md must never be replaced.
            try data.write(to: target, options: .withoutOverwriting)
        }
    }

    static func attempt(
        in root: URL,
        template: String,
        writer: Writer
    ) -> Result<URL, Failure> {
        let target = root.standardizedFileURL.appendingPathComponent("AGENTS.md")
        do {
            try writer(Data(template.utf8), target)
            return .success(target)
        } catch {
            return .failure(classify(error))
        }
    }

    private static func classify(_ error: any Error) -> Failure {
        if let cocoaError = error as? CocoaError {
            switch cocoaError.code {
            case .fileWriteFileExists:
                return .destinationExists
            case .fileReadNoPermission, .fileWriteNoPermission, .fileWriteVolumeReadOnly:
                return .permissionDenied
            case .fileWriteOutOfSpace:
                return .diskFull
            default:
                break
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(EEXIST):
                return .destinationExists
            case Int(EACCES), Int(EPERM), Int(EROFS):
                return .permissionDenied
            case Int(ENOSPC):
                return .diskFull
            default:
                break
            }
        }
        return .other
    }
}

private struct WorkspaceMoveSheet: View {
    @Environment(\.dismiss) private var dismiss

    let root: URL
    let item: FileNode
    let move: @MainActor (URL) async -> WorkspaceMoveOutcome

    @StateObject private var controller: WorkspaceMoveController

    init(
        root: URL,
        item: FileNode,
        move: @escaping @MainActor (URL) async -> WorkspaceMoveOutcome
    ) {
        self.root = root
        self.item = item
        self.move = move
        _controller = StateObject(wrappedValue: WorkspaceMoveController(root: root, item: item))
    }

    private var visibleDirectories: [URL] { controller.visibleDirectories }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Move \(item.name)")
                    .font(.title3.weight(.semibold))
                Text("Choose a folder inside \(root.lastPathComponent). The item will keep its name.")
                    .font(.callout)
                    .foregroundStyle(.kaisolaSecondary)
            }

            TextField("Search folders", text: $controller.searchText)
                .textFieldStyle(.roundedBorder)
                .disabled(controller.isMoving)

            Group {
                if controller.isLoading {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Finding project folders…")
                            .font(.caption)
                            .foregroundStyle(.kaisolaSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleDirectories.isEmpty {
                    ContentUnavailableView(
                        controller.searchText.isEmpty ? "No Other Folders" : "No Matching Folders",
                        systemImage: "folder.badge.minus",
                        description: Text(
                            controller.searchText.isEmpty
                                ? "This item has no safe cross-directory destination."
                                : "Try a different folder search."
                        )
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(visibleDirectories, id: \.path) { directory in
                                let isSelected = controller.selectedPath == directory.path
                                Button {
                                    controller.select(directory)
                                } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: directory.path == root.standardizedFileURL.path
                                            ? "shippingbox"
                                            : "folder")
                                            .foregroundStyle(isSelected ? Color.accentColor : .kaisolaSecondary)
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
                                .disabled(controller.isMoving)
                                .accessibilityLabel("Move destination \(destinationLabel(directory))")
                                .accessibilityValue(
                                    isSelected
                                        ? "Selected. \(destinationLabel(directory))"
                                        : "Not selected"
                                )
                                .accessibilityHint("Choose this folder as the move destination")
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
            if let failure = controller.failureMessage {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Text(failure)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    Color.orange.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Move failed. \(failure)")
                .accessibilityIdentifier("workspace.move.failure")
            }
            HStack(spacing: 9) {
                if controller.isMoving {
                    ProgressView().controlSize(.small)
                    Text("Moving \(item.name)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("workspace.move.progress")
                }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    // The move is already in flight; leaving now would put its
                    // result back where this sheet cannot show it.
                    .disabled(controller.isMoving)
                Button(controller.failureMessage == nil ? "Move" : "Retry") {
                    Task { await submit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.canSubmit)
                .accessibilityIdentifier("workspace.move.commit")
            }
        }
        .padding(20)
        .frame(width: 460, height: 440)
        .interactiveDismissDisabled(controller.isMoving)
        .task(id: item.id) {
            await controller.loadDestinations()
        }
        .onChange(of: controller.selectedPath) { _, _ in
            announceSelection()
        }
    }

    /// The sheet leaves only once the move is confirmed. Anything else keeps
    /// the item, the destination and the diagnostic on screen together.
    private func submit() async {
        await controller.submit(move)
        if controller.isFinished { dismiss() }
    }

    private func destinationLabel(_ directory: URL) -> String {
        controller.destinationLabel(directory)
    }

    private func announceSelection() {
        guard let announcement = controller.selectionAnnouncement else { return }
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
    /// The row's voice; the selected row hands in a heavier one.
    var font: Font = .callout
    /// How far the name's last characters take to fade out.
    var fadeWidth: CGFloat = 18

    @State private var textWidth: CGFloat = 0
    @State private var availableWidth: CGFloat = 0

    private var overflows: Bool { textWidth > availableWidth + 0.5 }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Text(text)
                    .font(font)
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

/// The project's starter AGENTS.md — the emerging convention agent CLIs read
/// for repo-specific guidance.
///
/// Creation is its own type because the rail may only open a document it can
/// prove is on disk. The write is exclusive (an existing file is never
/// overwritten), a partial write is discarded rather than left looking like a
/// real instruction file, and every failure comes back with advice a person can
/// act on before retrying the same action.
enum WorkspaceInstructionFile {
    static let fileName = "AGENTS.md"

    enum Outcome: Equatable, Sendable {
        /// This action wrote the starter file.
        case created(URL)
        /// A regular file was already there; nothing was written.
        case alreadyExisted(URL)

        /// The file the rail may open. It exists in both cases — that is the
        /// point of returning an outcome rather than a bare path.
        var url: URL {
            switch self {
            case let .created(url), let .alreadyExisted(url): url
            }
        }

        var didWrite: Bool {
            if case .created = self { true } else { false }
        }
    }

    struct Failure: Error, Equatable, Sendable {
        enum Reason: Equatable, Sendable {
            case collision
            case permission
            case diskFull
            case workspaceUnavailable
            case unknown
        }

        let reason: Reason

        /// Each message names the cause the person can clear, because the alert
        /// that carries it offers the action again straight away.
        var message: String {
            switch reason {
            case .collision:
                "A folder or link named \(fileName) is already in this project. Rename or remove it, then try again."
            case .permission:
                "Kaisola doesn't have permission to write \(fileName) in this project folder."
            case .diskFull:
                "The disk is full, so \(fileName) wasn't written. Free some space, then try again."
            case .workspaceUnavailable:
                "The project folder is unavailable, so \(fileName) wasn't written."
            case .unknown:
                "Kaisola couldn't write \(fileName). Check the project folder, then try again."
            }
        }
    }

    /// Creates the starter file when it is missing. Success means a real file
    /// is on disk right now; a failure never yields a path to open.
    static func create(in workspaceRoot: URL) -> Result<Outcome, Failure> {
        let root = workspaceRoot.standardizedFileURL
        var rootIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &rootIsDirectory),
              rootIsDirectory.boolValue else {
            return .failure(Failure(reason: .workspaceUnavailable))
        }

        let target = root.appendingPathComponent(fileName).standardizedFileURL
        var targetIsDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &targetIsDirectory) {
            // A folder or a link under that name is a collision, not an
            // instruction file: opening it would preview something that is not
            // the guidance the action promised.
            guard !targetIsDirectory.boolValue else {
                return .failure(Failure(reason: .collision))
            }
            let values = try? target.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else {
                return .failure(Failure(reason: .collision))
            }
            return .success(.alreadyExisted(target))
        }

        if let failure = write(template, to: target) {
            return .failure(failure)
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            return .failure(Failure(reason: .unknown))
        }
        return .success(.created(target))
    }

    /// errno is the only signal that separates a full disk from a folder the
    /// app may not write to, and the two need different advice.
    static func failure(forErrno code: Int32) -> Failure {
        switch code {
        case EEXIST:
            Failure(reason: .collision)
        case EACCES, EPERM, EROFS:
            Failure(reason: .permission)
        case ENOSPC, EDQUOT, EFBIG:
            Failure(reason: .diskFull)
        case ENOENT, ENOTDIR:
            Failure(reason: .workspaceUnavailable)
        default:
            Failure(reason: .unknown)
        }
    }

    static let template = """
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

    /// Exclusive create plus a complete write, or nothing at all. `O_EXCL`
    /// keeps the filesystem the collision authority even if a file appears
    /// between the check above and this call.
    private static func write(_ contents: String, to destination: URL) -> Failure? {
        let descriptor = destination.path.withCString { path in
            Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        }
        guard descriptor >= 0 else { return failure(forErrno: errno) }

        let bytes = Array(contents.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress! + offset, bytes.count - offset)
            }
            if written < 0 {
                let code = errno
                if code == EINTR { continue }
                return discard(descriptor, at: destination, reporting: failure(forErrno: code))
            }
            offset += written
        }
        // A truncated instruction file is worse than none: it would read as
        // real guidance, and the retry would then collide with itself.
        guard Darwin.close(descriptor) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: destination)
            return failure(forErrno: code)
        }
        return nil
    }

    private static func discard(
        _ descriptor: Int32,
        at destination: URL,
        reporting failure: Failure
    ) -> Failure {
        Darwin.close(descriptor)
        try? FileManager.default.removeItem(at: destination)
        return failure
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
