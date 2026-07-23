import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a file resolves to for previewing/editing. Pure so tests can drive it.
enum FilePreviewContent: Equatable {
    case text(String)
    case markdown(String)
    case csv(String)
    case json(String)
    case html
    case image
    case tooLarge(Int)
    case binary
    case unreadable

    static let maxTextBytes = 1_048_576
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff", "svg", "icns"]

    static func load(url: URL) -> FilePreviewContent {
        let path = url.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int else { return .unreadable }
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        // HTML renders from disk in a WKWebView, so it skips the text cap.
        if ext == "html" || ext == "htm" { return .html }
        guard size <= maxTextBytes else { return .tooLarge(size) }
        guard let data = FileManager.default.contents(atPath: path) else { return .unreadable }
        guard let text = String(data: data, encoding: .utf8) else { return .binary }
        if ext == "csv" || ext == "tsv" { return .csv(text) }
        if ext == "json" { return .json(text) }
        return ext == "md" || ext == "markdown" ? .markdown(text) : .text(text)
    }
}

/// File preview/editor pane: UTF-8 text is editable with ⌘S save + revert,
/// markdown renders styled (with a raw-source toggle), images display, and
/// binary/oversized files degrade to a clear notice.
struct FilePreviewView: View {
    let url: URL
    let close: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var content: FilePreviewContent = .unreadable
    @State private var draft = ""
    @State private var savedText = ""
    @State private var showMarkdownSource = false
    /// Text (non-markdown) files default to a read-only, syntax-highlighted
    /// view; this toggle drops into the plain `TextEditor` for editing.
    @State private var isEditingText = false
    /// Cached highlighted rendering of `draft`, recomputed only when the source,
    /// language, or appearance changes (never on every keystroke).
    @State private var highlighted = AttributedString("")
    @State private var saveError: String?
    /// The file actually shown; lags `url` while an unsaved-changes prompt is up.
    @State private var displayedURL: URL?
    /// A navigation/close blocked on unsaved changes, awaiting the user.
    @State private var pendingAction: PendingAction?

    private enum PendingAction: Equatable {
        case navigate(URL)
        case close
    }

    private var isDirty: Bool { draft != savedText }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body(for: content)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { displayedURL = url; load() }
        .onChange(of: url) { _, newURL in
            // Never silently drop unsaved edits: block the switch behind a
            // Save / Discard / Cancel prompt.
            if isDirty, newURL != displayedURL {
                pendingAction = .navigate(newURL)
            } else {
                displayedURL = newURL
                load()
            }
        }
        // Re-highlight when appearance flips or when returning to read mode with
        // edited (or reverted/discarded) text. Skipped while editing so typing
        // never pays the highlight cost.
        .onChange(of: colorScheme) { _, _ in refreshHighlight() }
        .onChange(of: isEditingText) { _, editing in if !editing { refreshHighlight() } }
        .onChange(of: draft) { _, _ in if !isEditingText { refreshHighlight() } }
        .confirmationDialog(
            "Unsaved changes",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })
        ) {
            Button("Save") {
                // Only navigate away once the write actually succeeds — a failed
                // save (read-only file, disk full, file vanished) must keep the
                // pane on the current file with the draft and error intact, never
                // silently discard the edits by navigating/closing anyway.
                if save() {
                    completePendingAction()
                } else {
                    pendingAction = nil
                }
            }
            Button("Discard Changes", role: .destructive) {
                draft = savedText
                completePendingAction()
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text("\(displayedURL?.lastPathComponent ?? "This file") has unsaved changes.")
        }
    }

    private func completePendingAction() {
        switch pendingAction {
        case let .navigate(next):
            displayedURL = next
            load()
        case .close:
            close()
        case nil:
            break
        }
        pendingAction = nil
    }

    private func requestClose() {
        if isDirty {
            pendingAction = .close
        } else {
            close()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
            Text((displayedURL ?? url).lastPathComponent).font(.subheadline.weight(.medium))
            if isDirty {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    .accessibilityLabel("Unsaved changes")
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            if case .markdown = content {
                Toggle("Source", isOn: $showMarkdownSource)
                    .toggleStyle(.button)
                    .controlSize(.small)
            }
            if case .text = content {
                Toggle("Edit", isOn: $isEditingText)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Switch between the read-only highlighted view and editing")
            }
            if isEditable {
                Button("Revert") { draft = savedText }
                    .disabled(!isDirty)
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty)
            }
            Button {
                requestClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Close the file preview")
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    private var isEditable: Bool {
        switch content {
        case .text, .markdown: true
        default: false
        }
    }

    @ViewBuilder
    private func body(for content: FilePreviewContent) -> some View {
        switch content {
        case .text:
            if isEditingText {
                editor
            } else {
                ScrollView {
                    Text(highlighted)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        case .markdown:
            if showMarkdownSource {
                editor
            } else {
                ScrollView {
                    Text(Self.renderMarkdown(draft))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        case .image:
            if let image = NSImage(contentsOf: displayedURL ?? url) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 1200)
                        .padding(16)
                }
            } else {
                ContentUnavailableView("Could not load image", systemImage: "photo")
            }
        case let .csv(text):
            CsvPreview(text: text)
        case let .json(text):
            JsonPreview(text: text)
        case .html:
            HtmlFilePreview(fileURL: displayedURL ?? url)
        case let .tooLarge(size):
            ContentUnavailableView(
                "File too large to preview",
                systemImage: "doc.zipper",
                description: Text("\(size / 1024) KB — the preview caps at \(FilePreviewContent.maxTextBytes / 1024) KB.")
            )
        case .binary:
            ContentUnavailableView("Binary file", systemImage: "doc", description: Text("No text preview available."))
        case .unreadable:
            ContentUnavailableView("Could not read file", systemImage: "exclamationmark.triangle")
        }
    }

    private var editor: some View {
        TextEditor(text: $draft)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
    }

    private func load() {
        content = FilePreviewContent.load(url: displayedURL ?? url)
        switch content {
        case let .text(text), let .markdown(text):
            draft = text
            savedText = text
        default:
            draft = ""
            savedText = ""
        }
        // Every newly opened file starts in read mode.
        isEditingText = false
        saveError = nil
        refreshHighlight()
    }

    /// Rebuild the syntax-highlighted rendering of `draft` for the current file
    /// and appearance. Non-highlightable extensions (and non-text content) fall
    /// back to a plain monospaced rendering. Pure and cheap — the highlighter
    /// caps and degrades on its own.
    private func refreshHighlight() {
        guard case .text = content else {
            highlighted = AttributedString(draft)
            return
        }
        let ext = (displayedURL ?? url).pathExtension
        guard let language = SyntaxHighlighter.language(forExtension: ext) else {
            highlighted = AttributedString(draft)
            return
        }
        let theme: SyntaxHighlighter.Theme = colorScheme == .dark ? .dark : .light
        highlighted = SyntaxHighlighter.highlight(draft, language: language, theme: theme)
    }

    /// Write the draft to disk. Returns whether the write succeeded, so callers
    /// gating navigation on a save (the unsaved-changes dialog) never discard
    /// edits on failure.
    @discardableResult
    private func save() -> Bool {
        do {
            try draft.write(to: displayedURL ?? url, atomically: true, encoding: .utf8)
            savedText = draft
            saveError = nil
            ToastCenter.shared.show("Saved \((displayedURL ?? url).lastPathComponent)", style: .success)
            return true
        } catch {
            saveError = error.localizedDescription
            ToastCenter.shared.show(error.localizedDescription, style: .error)
            return false
        }
    }

    /// Markdown → AttributedString with a plain-text fallback so a parse
    /// failure can never blank the preview. Pure, hence nonisolated (CI's
    /// stricter inference otherwise pins View statics to the main actor).
    nonisolated static func renderMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// The workspace rail: a lazy file tree for the active project (⌘B). Clicking a
/// file opens it in the preview pane.
struct WorkspaceRailView: View {
    let root: URL
    let openFile: (URL) -> Void

    @State private var expanded: Set<String> = []
    @State private var refreshToken = 0
    /// Live FSEvents watcher — agent writes refresh the tree automatically.
    @StateObject private var watcher: WorkspaceWatcher

    init(root: URL, openFile: @escaping (URL) -> Void) {
        self.root = root
        self.openFile = openFile
        _watcher = StateObject(wrappedValue: WorkspaceWatcher(root: root))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                nodeRows(for: root, depth: 0)
            }
            .padding(.vertical, 6)
        }
        .frame(width: 230)
        .background(.background.secondary)
        .id(refreshToken)
        .onChange(of: watcher.changeToken) { _, _ in refreshToken += 1 }
        .contextMenu {
            Button("Refresh") {
                ProjectFileIndex.shared.invalidate()
                refreshToken += 1
            }
            Button("New AGENTS.md") {
                let target = root.appendingPathComponent("AGENTS.md")
                if !FileManager.default.fileExists(atPath: target.path) {
                    try? Self.agentsTemplate.write(to: target, atomically: true, encoding: .utf8)
                    ProjectFileIndex.shared.invalidate()
                    refreshToken += 1
                }
                openFile(target)
            }
        }
        .accessibilityLabel("Workspace files")
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
        ForEach(ProjectFiles.children(of: directory)) { node in
            nodeRow(node, depth: depth)
            if node.isDirectory, expanded.contains(node.id) {
                AnyView(nodeRows(for: node.url, depth: depth + 1))
            }
        }
    }

    private func nodeRow(_ node: FileNode, depth: Int) -> some View {
        Button {
            if node.isDirectory {
                if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
            } else {
                openFile(node.url)
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
                Text(node.name).font(.callout).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2.5)
            .padding(.leading, CGFloat(depth) * 14 + 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
