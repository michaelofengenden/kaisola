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
    /// Project root grants HTML previews access to their own relative assets
    /// (styles, scripts, images) without granting the rest of the filesystem.
    let workspaceRoot: URL?
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
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>?
    @State private var highlightTask: Task<Void, Never>?

    private enum PendingAction: Equatable {
        case navigate(URL)
        case close
    }

    private var isDirty: Bool { draft != savedText }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                body(for: content)
                if isLoading {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Opening \((displayedURL ?? url).lastPathComponent)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
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
        .onDisappear {
            loadTask?.cancel()
            highlightTask?.cancel()
        }
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
                MarkdownDocumentView(source: draft)
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
            HtmlFilePreview(fileURL: displayedURL ?? url, readAccessRoot: workspaceRoot)
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
        loadTask?.cancel()
        highlightTask?.cancel()
        let target = displayedURL ?? url
        isLoading = true
        loadTask = Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                FilePreviewContent.load(url: target)
            }.value
            guard !Task.isCancelled, target == (displayedURL ?? url) else { return }
            content = loaded
            switch loaded {
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
            isLoading = false
            refreshHighlight()
        }
    }

    /// Rebuild the syntax-highlighted rendering of `draft` for the current file
    /// and appearance. Non-highlightable extensions (and non-text content) fall
    /// back to a plain monospaced rendering. Pure and cheap — the highlighter
    /// caps and degrades on its own.
    private func refreshHighlight() {
        highlightTask?.cancel()
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
        let source = draft
        highlightTask = Task {
            let result = await Task.detached(priority: .utility) {
                SyntaxHighlighter.highlight(source, language: language, theme: theme)
            }.value
            guard !Task.isCancelled, source == draft else { return }
            highlighted = result
        }
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
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        )) ?? AttributedString(text)
    }
}

/// Small native Markdown document model. `Text(AttributedString(markdown:))`
/// renders inline emphasis but ignores most block presentation intents, which
/// is why headings, lists, quotes, tables, and fenced code previously collapsed
/// into an almost-plain paragraph. This parser preserves those structural
/// blocks while still delegating inline Markdown to Foundation.
struct MarkdownDocument: Equatable, Sendable {
    enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case listItem(indent: Int, marker: String, text: String)
        case quote(String)
        case code(language: String?, text: String)
        case table(headers: [String], rows: [[String]])
        case rule
    }

    let blocks: [Block]

    static func parse(_ source: String) -> MarkdownDocument {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var blocks: [Block] = []
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let languageToken = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(
                    language: languageToken.isEmpty ? nil : languageToken,
                    text: code.joined(separator: "\n")
                ))
                continue
            }
            if let heading = heading(in: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }
            if let item = listItem(in: line) {
                flushParagraph()
                blocks.append(.listItem(indent: item.indent, marker: item.marker, text: item.text))
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quote.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }
            if index + 1 < lines.count,
               line.contains("|"),
               isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let headers = tableCells(line)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: Array(rows.prefix(100))))
                continue
            }
            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        return MarkdownDocument(blocks: blocks)
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(in line: String) -> (indent: Int, marker: String, text: String)? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        let body = line.dropFirst(leading.count)
        for bullet in ["- ", "* ", "+ "] where body.hasPrefix(bullet) {
            return (indent, "•", String(body.dropFirst(2)))
        }
        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty, body.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return (indent, "\(digits).", String(body.dropFirst(digits.count + 2)))
    }

    private static func tableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return core.count >= 3 && core.allSatisfy { $0 == "-" }
        }
    }
}

private struct MarkdownDocumentView: View {
    let source: String

    private var document: MarkdownDocument { MarkdownDocument.parse(source) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownDocument.Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 8 : 2)
        case let .paragraph(text):
            Text(inline(text))
                .font(.body)
                .lineSpacing(4)
        case let .listItem(indent, marker, text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(marker)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                Text(inline(text)).lineSpacing(3)
            }
            .padding(.leading, CGFloat(indent) * 20)
        case let .quote(text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: 3)
                Text(inline(text))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
            }
            .padding(.vertical, 4)
        case let .code(language, text):
            VStack(alignment: .leading, spacing: 0) {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 9)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(verbatim: text)
                        .font(.system(.callout, design: .monospaced))
                        .lineSpacing(3)
                        .padding(12)
                }
            }
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        case let .table(headers, rows):
            MarkdownTable(headers: headers, rows: rows)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .largeTitle.bold()
        case 2: .title.bold()
        case 3: .title2.weight(.semibold)
        case 4: .title3.weight(.semibold)
        default: .headline
        }
    }
}

private struct MarkdownTable: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow { cells(headers, header: true) }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow { cells(row, header: false) }
                        .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func cells(_ values: [String], header: Bool) -> some View {
        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
            Text(value)
                .font(header ? .callout.weight(.semibold) : .callout)
                .frame(minWidth: 100, maxWidth: 280, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(header ? Color.primary.opacity(0.07) : .clear)
                .overlay(alignment: .trailing) { Divider() }
        }
    }
}

/// The workspace rail: a lazy file tree for the active project (⌘B). Clicking a
/// file opens it in the preview pane.
struct WorkspaceRailView: View {
    @EnvironmentObject private var settings: NativePreviewSettings
    let root: URL
    let openFile: (URL) -> Void
    let close: () -> Void

    @State private var expanded: Set<String> = []
    @State private var searchText = ""
    /// Live FSEvents watcher — agent writes refresh the tree automatically.
    @StateObject private var watcher: WorkspaceWatcher
    @StateObject private var tree: WorkspaceTreeModel

    init(root: URL, openFile: @escaping (URL) -> Void, close: @escaping () -> Void) {
        self.root = root
        self.openFile = openFile
        self.close = close
        _watcher = StateObject(wrappedValue: WorkspaceWatcher(root: root))
        _tree = StateObject(wrappedValue: WorkspaceTreeModel(root: root))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)
                Text(root.lastPathComponent)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh files")
                Button(action: close) { Image(systemName: "sidebar.right") }
                    .buttonStyle(.borderless)
                    .help("Close Files (Command-B)")
                    .accessibilityLabel("Close file browser")
            }
            .padding(.horizontal, 10)
            .frame(height: 32)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search files", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 8)
            .padding(.bottom, 7)

            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        nodeRows(for: root, depth: 0)
                    }
                    .padding(.vertical, 6)
                }
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
                                openFile(root.appendingPathComponent(path))
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "doc.text")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(path)
                                        .font(.callout)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .frame(minWidth: 205, maxWidth: .infinity, maxHeight: .infinity)
        .background {
            SidebarBackdropView(appearance: settings.sidebarAppearance)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.8))
                .frame(width: 1)
                .shadow(color: .black.opacity(0.12), radius: 2, x: -1)
        }
        .task { tree.load(root) }
        .onChange(of: searchText) { _, query in tree.search(query) }
        .onChange(of: watcher.changeToken) { _, _ in
            tree.refresh(expandedDirectories: expanded.map { URL(fileURLWithPath: $0, isDirectory: true) })
            tree.search(searchText)
        }
        .contextMenu {
            Button("Refresh", action: refresh)
            Button("New AGENTS.md") {
                let target = root.appendingPathComponent("AGENTS.md")
                if !FileManager.default.fileExists(atPath: target.path) {
                    try? Self.agentsTemplate.write(to: target, atomically: true, encoding: .utf8)
                    ProjectFileIndex.shared.invalidate()
                    tree.refresh(expandedDirectories: expanded.map { URL(fileURLWithPath: $0, isDirectory: true) })
                }
                openFile(target)
            }
        }
        .accessibilityLabel("Workspace files")
    }

    private func refresh() {
        ProjectFileIndex.shared.invalidate()
        tree.refresh(expandedDirectories: expanded.map { URL(fileURLWithPath: $0, isDirectory: true) })
        tree.search(searchText)
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
