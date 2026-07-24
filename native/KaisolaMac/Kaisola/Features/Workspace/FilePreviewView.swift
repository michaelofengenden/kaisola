import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a file resolves to for previewing/editing. Pure so tests can drive it.
enum FilePreviewContent: Equatable, Sendable {
    case text(String)
    case markdown(String)
    case csv(String)
    case json(String)
    case html(String)
    case docx
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
        if ext == "docx" { return size <= maxDocumentBytes ? .docx : .tooLarge(size) }
        guard size <= maxTextBytes else { return .tooLarge(size) }
        guard let data = FileManager.default.contents(atPath: path) else { return .unreadable }
        guard let text = String(data: data, encoding: .utf8) else { return .binary }
        if ext == "html" || ext == "htm" { return .html(text) }
        if ext == "csv" || ext == "tsv" { return .csv(text) }
        if ext == "json" { return .json(text) }
        return ext == "md" || ext == "markdown" ? .markdown(text) : .text(text)
    }

    static let maxDocumentBytes = 20 * 1_048_576
}

/// AppKit's Office Open XML reader/writer is synchronous and the attributed
/// string classes predate Sendable. Keep that work off the main actor and move
/// the immutable result across the boundary in this explicit wrapper.
struct RichDocumentPayload: @unchecked Sendable {
    let value: NSAttributedString
}

enum RichDocumentIO {
    static func load(url: URL) -> RichDocumentPayload? {
        guard let value = try? NSAttributedString(
            url: url,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
            documentAttributes: nil
        ) else { return nil }
        return RichDocumentPayload(value: value)
    }

    static func write(_ value: NSAttributedString, to url: URL) throws {
        let data = try value.data(
            from: NSRange(location: 0, length: value.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
        try data.write(to: url, options: .atomic)
    }
}

private struct FilePreviewSnapshot: Sendable {
    let content: FilePreviewContent
    let modificationDate: Date?
}

private enum FilePreviewSaveResult: Sendable {
    case saved(Date?)
    case changedOnDisk
    case failed(String)
}

/// Disk reads/writes used by the preview are deliberately actor-independent so
/// they can run on a utility executor. The modification-date guard prevents an
/// agent edit that lands after the preview opened from being silently replaced.
enum FilePreviewDiskState {
    nonisolated static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    nonisolated static func changed(onDisk url: URL, since expected: Date?) -> Bool {
        modificationDate(of: url) != expected
    }

    fileprivate nonisolated static func writeText(
        _ text: String,
        to url: URL,
        expectedModificationDate: Date?,
        force: Bool
    ) -> FilePreviewSaveResult {
        guard force || !changed(onDisk: url, since: expectedModificationDate) else {
            return .changedOnDisk
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return .saved(modificationDate(of: url))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// NSAttributedString's DOCX importer/exporter is synchronous. A dedicated
/// actor serializes rich-document work off the MainActor, so rapid file switches
/// cannot pile up AppKit parses or freeze terminal rendering.
private actor RichDocumentWorker {
    static let shared = RichDocumentWorker()

    func load(url: URL) -> RichDocumentPayload? {
        RichDocumentIO.load(url: url)
    }

    func write(
        _ payload: RichDocumentPayload,
        to url: URL,
        expectedModificationDate: Date?,
        force: Bool
    ) -> FilePreviewSaveResult {
        guard force || !FilePreviewDiskState.changed(onDisk: url, since: expectedModificationDate) else {
            return .changedOnDisk
        }
        do {
            try RichDocumentIO.write(payload.value, to: url)
            return .saved(FilePreviewDiskState.modificationDate(of: url))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

private struct RichDocumentCommand: Equatable {
    enum Kind: Equatable { case bold, italic, underline, heading, bulletList }
    let id = UUID()
    let kind: Kind
}

/// File preview/editor pane: UTF-8 text is editable with ⌘S save + revert,
/// markdown renders styled (with a raw-source toggle), images display, and
/// binary/oversized files degrade to a clear notice.
struct FilePreviewView: View {
    let url: URL
    /// Project root grants HTML previews access to their own relative assets
    /// (styles, scripts, images) without granting the rest of the filesystem.
    let workspaceRoot: URL?
    /// Restores AppModel's selection when a pending file switch is cancelled.
    let restoreSelection: (URL) -> Void
    let close: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var content: FilePreviewContent = .unreadable
    @State private var draft = ""
    @State private var savedText = ""
    @State private var richDraft = NSAttributedString(string: "")
    @State private var savedRichText = NSAttributedString(string: "")
    @State private var showMarkdownSource = false
    /// Text (non-markdown) files default to a read-only, syntax-highlighted
    /// view; this toggle drops into the plain `TextEditor` for editing.
    @State private var isEditingText = false
    /// Cached highlighted rendering of `draft`, recomputed only when the source,
    /// language, or appearance changes (never on every keystroke).
    @State private var highlighted = AttributedString("")
    @State private var saveError: String?
    /// The URL that produced the currently rendered draft. It deliberately
    /// stays unchanged while another URL loads, so Save can never target the
    /// incoming file with the outgoing file's contents.
    @State private var loadedURL: URL?
    @State private var loadingURL: URL?
    @State private var loadedModificationDate: Date?
    /// A navigation/close blocked on unsaved changes, awaiting the user.
    @State private var pendingAction: PendingAction?
    @State private var showUnsavedPrompt = false
    @State private var showExternalChangePrompt = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var loadTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var highlightTask: Task<Void, Never>?
    @State private var documentZoom: CGFloat = 1
    @State private var previewRevision = 0
    @State private var richDocumentCommand: RichDocumentCommand?

    private enum PendingAction: Equatable {
        case navigate(URL)
        case close
    }

    private var isDirty: Bool {
        if case .docx = content { return !richDraft.isEqual(to: savedRichText) }
        return draft != savedText
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                body(for: content)
                    .allowsHitTesting(!isLoading && !isSaving)
                if isLoading {
                    ZStack {
                        Rectangle().fill(.clear).contentShape(Rectangle())
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Opening \((loadingURL ?? url).lastPathComponent)…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.8)
        }
        .onAppear { beginLoad(url) }
        .onChange(of: url) { _, newURL in
            guard newURL != loadedURL, newURL != loadingURL else { return }
            // Never silently drop unsaved edits: block the switch behind a
            // Save / Discard / Cancel prompt.
            if isDirty {
                pendingAction = .navigate(newURL)
                showUnsavedPrompt = true
            } else {
                beginLoad(newURL)
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
            saveTask?.cancel()
            highlightTask?.cancel()
        }
        .confirmationDialog(
            "Unsaved changes",
            isPresented: $showUnsavedPrompt
        ) {
            Button("Save") {
                save(advancePendingAction: true)
            }
            Button("Discard Changes", role: .destructive) {
                draft = savedText
                richDraft = savedRichText
                completePendingAction()
            }
            Button("Cancel", role: .cancel) {
                pendingAction = nil
                if let loadedURL { restoreSelection(loadedURL) }
            }
        } message: {
            Text("\(loadedURL?.lastPathComponent ?? "This file") has unsaved changes.")
        }
        .confirmationDialog("File changed on disk", isPresented: $showExternalChangePrompt) {
            Button("Reload from Disk") {
                pendingAction = nil
                if let loadedURL { beginLoad(loadedURL) }
            }
            Button("Overwrite", role: .destructive) {
                save(force: true, advancePendingAction: pendingAction != nil)
            }
            Button("Cancel", role: .cancel) {
                if let loadedURL { restoreSelection(loadedURL) }
                pendingAction = nil
            }
        } message: {
            Text("An agent or another app edited this file after it was opened. Reload it or explicitly overwrite the newer version.")
        }
    }

    private func completePendingAction() {
        switch pendingAction {
        case let .navigate(next):
            beginLoad(next)
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
            showUnsavedPrompt = true
        } else {
            close()
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text((loadingURL ?? loadedURL ?? url).lastPathComponent)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if isDirty {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    .accessibilityLabel("Unsaved changes")
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            if isLoading || isSaving { ProgressView().controlSize(.mini) }
            if case .markdown = content {
                Button { showMarkdownSource.toggle() } label: {
                    Image(systemName: showMarkdownSource ? "doc.richtext.fill" : "doc.plaintext")
                }
                .buttonStyle(.borderless)
                .help(showMarkdownSource ? "Show rendered Markdown" : "Edit Markdown source")
            } else if case .text = content {
                editModeButton(help: "Edit text")
            } else if case .html = content {
                editModeButton(help: "Edit HTML source")
            }
            if isEditable {
                Button { save() } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty || isLoading || isSaving)
                .help("Save")
            }
            previewOptionsMenu
            Button {
                requestClose()
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .help("Minimize the document preview")
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(.thinMaterial)
    }

    private func editModeButton(help: String) -> some View {
        Button { isEditingText.toggle() } label: {
            Image(systemName: isEditingText ? "eye" : "pencil")
        }
        .buttonStyle(.borderless)
        .help(isEditingText ? "Show preview" : help)
    }

    private var previewOptionsMenu: some View {
        Menu {
            if case .docx = content {
                Section("Format") {
                    Button("Bold") { richDocumentCommand = RichDocumentCommand(kind: .bold) }
                    Button("Italic") { richDocumentCommand = RichDocumentCommand(kind: .italic) }
                    Button("Underline") { richDocumentCommand = RichDocumentCommand(kind: .underline) }
                    Button("Heading") { richDocumentCommand = RichDocumentCommand(kind: .heading) }
                    Button("Bulleted list") { richDocumentCommand = RichDocumentCommand(kind: .bulletList) }
                }
            }
            if supportsZoom {
                Section("Zoom — \(Int((documentZoom * 100).rounded()))%") {
                    Button("Zoom In") { adjustZoom(0.1) }.disabled(documentZoom >= 2)
                    Button("Zoom Out") { adjustZoom(-0.1) }.disabled(documentZoom <= 0.65)
                    Button("Actual Size") { documentZoom = 1 }.disabled(documentZoom == 1)
                }
            }
            if isEditable {
                Divider()
                Button("Revert Changes") {
                    if case .docx = content { richDraft = savedRichText }
                    else { draft = savedText }
                }
                .disabled(!isDirty)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Document options")
    }

    private var supportsZoom: Bool {
        switch content {
        case .text, .markdown, .html, .docx, .image: true
        default: false
        }
    }

    private var isEditable: Bool {
        switch content {
        case .text, .markdown, .html, .docx: true
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
                        .font(.system(size: 13 * documentZoom, design: .monospaced))
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        case .markdown:
            if showMarkdownSource {
                editor
            } else {
                MarkdownDocumentView(source: draft, zoom: documentZoom)
            }
        case .image:
            if let image = NSImage(contentsOf: loadedURL ?? url) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 1200 * documentZoom)
                        .padding(16)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                ContentUnavailableView("Could not load image", systemImage: "photo")
            }
        case let .csv(text):
            CsvPreview(text: text)
        case let .json(text):
            JsonPreview(text: text)
        case .html:
            if isEditingText {
                editor
            } else {
                HtmlFilePreview(
                    fileURL: loadedURL ?? url,
                    readAccessRoot: workspaceRoot,
                    zoom: documentZoom,
                    contentRevision: previewRevision
                )
            }
        case .docx:
            RichDocumentEditor(text: $richDraft, zoom: documentZoom, command: richDocumentCommand)
                .background(Color(nsColor: .underPageBackgroundColor))
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor))
        case let .tooLarge(size):
            ContentUnavailableView(
                "File too large to preview",
                systemImage: "doc.zipper",
                description: Text("\(size / 1024) KB — bounded previews keep the workspace responsive.")
            )
        case .binary:
            ContentUnavailableView("Binary file", systemImage: "doc", description: Text("No text preview available."))
        case .unreadable:
            ContentUnavailableView("Could not read file", systemImage: "exclamationmark.triangle")
        }
    }

    private var editor: some View {
        TextEditor(text: $draft)
            .font(.system(size: 13 * documentZoom, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
    }

    private func beginLoad(_ target: URL) {
        loadTask?.cancel()
        highlightTask?.cancel()
        loadingURL = target
        isLoading = true
        saveError = nil
        loadTask = Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                FilePreviewSnapshot(
                    content: FilePreviewContent.load(url: target),
                    modificationDate: FilePreviewDiskState.modificationDate(of: target)
                )
            }.value
            let rich: RichDocumentPayload?
            if case .docx = snapshot.content {
                rich = await RichDocumentWorker.shared.load(url: target)
            } else {
                rich = nil
            }
            guard !Task.isCancelled, loadingURL == target else { return }
            if case .docx = snapshot.content, rich == nil {
                content = .unreadable
                loadedURL = target
                loadingURL = nil
                loadedModificationDate = snapshot.modificationDate
                isLoading = false
                return
            }
            content = snapshot.content
            switch snapshot.content {
            case let .text(text), let .markdown(text), let .html(text):
                draft = text
                savedText = text
            case .docx:
                richDraft = rich?.value ?? NSAttributedString(string: "")
                savedRichText = rich?.value.copy() as? NSAttributedString ?? NSAttributedString(string: "")
            default:
                draft = ""
                savedText = ""
            }
            // Every newly opened file starts in read mode.
            isEditingText = false
            showMarkdownSource = false
            documentZoom = 1
            loadedURL = target
            loadingURL = nil
            loadedModificationDate = snapshot.modificationDate
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
        let ext = (loadedURL ?? url).pathExtension
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

    /// Save exactly the snapshot currently displayed. `loadedURL` never moves
    /// until a load finishes, eliminating the old wrong-file race during fast
    /// tree navigation. The mtime check makes concurrent agent edits explicit.
    private func save(force: Bool = false, advancePendingAction: Bool = false) {
        guard let target = loadedURL, !isSaving else { return }
        let expectedDate = loadedModificationDate
        let textSnapshot = draft
        let richSnapshot = RichDocumentPayload(
            value: richDraft.copy() as? NSAttributedString ?? richDraft
        )
        let savingRichDocument: Bool = {
            if case .docx = content { return true }
            return false
        }()

        isSaving = true
        saveTask?.cancel()
        saveTask = Task {
            let result: FilePreviewSaveResult
            if savingRichDocument {
                result = await RichDocumentWorker.shared.write(
                    richSnapshot,
                    to: target,
                    expectedModificationDate: expectedDate,
                    force: force
                )
            } else {
                result = await Task.detached(priority: .userInitiated) {
                    FilePreviewDiskState.writeText(
                        textSnapshot,
                        to: target,
                        expectedModificationDate: expectedDate,
                        force: force
                    )
                }.value
            }
            guard !Task.isCancelled, loadedURL == target else { return }
            isSaving = false
            saveTask = nil
            switch result {
            case let .saved(modificationDate):
                loadedModificationDate = modificationDate
                if savingRichDocument { savedRichText = richSnapshot.value }
                else { savedText = textSnapshot }
                if case .html = content { previewRevision &+= 1 }
                saveError = nil
                ToastCenter.shared.show("Saved \(target.lastPathComponent)", style: .success)
                if advancePendingAction { completePendingAction() }
            case .changedOnDisk:
                showExternalChangePrompt = true
            case let .failed(message):
                saveError = message
                ToastCenter.shared.show(message, style: .error)
            }
        }
    }

    private func adjustZoom(_ delta: CGFloat) {
        documentZoom = min(2, max(0.65, ((documentZoom + delta) * 10).rounded() / 10))
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

/// Native rich-text editor for Office Open XML documents. NSTextView preserves
/// formatting and provides undo, find, selection, spell checking, and familiar
/// macOS editing semantics; the surrounding neutral canvas gives the document
/// a quiet page-like surface rather than another dense application toolbar.
private struct RichDocumentEditor: NSViewRepresentable {
    @Binding var text: NSAttributedString
    let zoom: CGFloat
    let command: RichDocumentCommand?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.65
        scrollView.maxMagnification = 2

        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 34, height: 30)
        textView.backgroundColor = .textBackgroundColor
        textView.textStorage?.setAttributedString(text)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        scrollView.magnification = zoom
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if !textView.attributedString().isEqual(to: text) {
            let selection = textView.selectedRange()
            context.coordinator.isApplyingExternalValue = true
            textView.textStorage?.setAttributedString(text)
            textView.setSelectedRange(NSIntersectionRange(
                selection,
                NSRange(location: 0, length: text.length)
            ))
            context.coordinator.isApplyingExternalValue = false
        }
        if abs(scrollView.magnification - zoom) > 0.001 {
            scrollView.setMagnification(zoom, centeredAt: NSPoint(
                x: scrollView.contentView.bounds.midX,
                y: scrollView.contentView.bounds.midY
            ))
        }
        if let command, context.coordinator.lastCommandID != command.id {
            context.coordinator.lastCommandID = command.id
            context.coordinator.apply(command.kind)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: NSAttributedString
        weak var textView: NSTextView?
        var isApplyingExternalValue = false
        var lastCommandID: UUID?

        init(text: Binding<NSAttributedString>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalValue,
                  let textView = notification.object as? NSTextView else { return }
            publish(textView)
        }

        func apply(_ command: RichDocumentCommand.Kind) {
            guard let textView, let storage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            switch command {
            case .bold:
                applyFontTrait(.boldFontMask, to: textView, storage: storage, selection: selection)
            case .italic:
                applyFontTrait(.italicFontMask, to: textView, storage: storage, selection: selection)
            case .underline:
                if selection.length > 0 {
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: selection)
                } else {
                    textView.typingAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
            case .heading:
                let font = NSFont.systemFont(ofSize: 22, weight: .semibold)
                if selection.length > 0 { storage.addAttribute(.font, value: font, range: selection) }
                else { textView.typingAttributes[.font] = font }
            case .bulletList:
                let paragraphRange = (textView.string as NSString).paragraphRange(for: selection)
                let source = (textView.string as NSString).substring(with: paragraphRange)
                let bulleted = source.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.isEmpty ? "" : "• \($0)" }
                    .joined(separator: "\n")
                textView.insertText(bulleted, replacementRange: paragraphRange)
            }
            publish(textView)
        }

        private func applyFontTrait(
            _ trait: NSFontTraitMask,
            to textView: NSTextView,
            storage: NSTextStorage,
            selection: NSRange
        ) {
            let manager = NSFontManager.shared
            if selection.length == 0 {
                let current = textView.typingAttributes[.font] as? NSFont
                    ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                textView.typingAttributes[.font] = manager.convert(current, toHaveTrait: trait)
                return
            }
            storage.enumerateAttribute(.font, in: selection) { value, range, _ in
                let current = value as? NSFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                storage.addAttribute(.font, value: manager.convert(current, toHaveTrait: trait), range: range)
            }
        }

        private func publish(_ textView: NSTextView) {
            text = textView.attributedString().copy() as? NSAttributedString
                ?? NSAttributedString(string: textView.string)
        }
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
            if let html = htmlBlock(in: lines, at: index) {
                flushParagraph()
                if let block = html.block { blocks.append(block) }
                index = html.nextIndex
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

    /// GitHub READMEs often use a small amount of presentational HTML for
    /// centered logos, headings, and link rows. Showing those tags verbatim is
    /// worse than ignoring their alignment, so translate the safe textual
    /// subset into the same native blocks used for Markdown. Image-only HTML
    /// is omitted until the native renderer gains workspace-confined embeds.
    private static func htmlBlock(
        in lines: [String],
        at index: Int
    ) -> (block: Block?, nextIndex: Int)? {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()

        for level in 1...6 where lower.hasPrefix("<h\(level)") {
            let closing = "</h\(level)>"
            let collected = collectHTML(lines: lines, from: index, closingTag: closing)
            let text = markdownFromHTML(collected.source)
            return (
                text.isEmpty ? nil : .heading(level: level, text: text),
                collected.nextIndex
            )
        }

        if lower.hasPrefix("<p") {
            let collected = collectHTML(lines: lines, from: index, closingTag: "</p>")
            let text = markdownFromHTML(collected.source)
            return (text.isEmpty ? nil : .paragraph(text), collected.nextIndex)
        }

        if lower.hasPrefix("<img") {
            return (nil, index + 1)
        }
        return nil
    }

    private static func collectHTML(
        lines: [String],
        from start: Int,
        closingTag: String
    ) -> (source: String, nextIndex: Int) {
        var fragments: [String] = []
        var cursor = start
        while cursor < lines.count {
            fragments.append(lines[cursor].trimmingCharacters(in: .whitespaces))
            cursor += 1
            if fragments.last?.lowercased().contains(closingTag) == true { break }
        }
        return (fragments.joined(separator: " "), cursor)
    }

    private static func markdownFromHTML(_ html: String) -> String {
        var value = html
        value = replacingHTML(value, pattern: #"<a\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"#, with: "[$2]($1)")
        value = replacingHTML(value, pattern: #"<strong\b[^>]*>(.*?)</strong>"#, with: "**$1**")
        value = replacingHTML(value, pattern: #"<b\b[^>]*>(.*?)</b>"#, with: "**$1**")
        value = replacingHTML(value, pattern: #"<em\b[^>]*>(.*?)</em>"#, with: "*$1*")
        value = replacingHTML(value, pattern: #"<i\b[^>]*>(.*?)</i>"#, with: "*$1*")
        value = replacingHTML(value, pattern: #"<code\b[^>]*>(.*?)</code>"#, with: "`$1`")
        value = replacingHTML(value, pattern: #"<img\b[^>]*>"#, with: "")
        value = replacingHTML(value, pattern: #"<br\s*/?>"#, with: " ")
        value = replacingHTML(value, pattern: #"<[^>]+>"#, with: "")
        value = value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        value = replacingHTML(value, pattern: #"\s+"#, with: " ")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingHTML(_ value: String, pattern: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: template)
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
    let zoom: CGFloat

    private var document: MarkdownDocument { MarkdownDocument.parse(source) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14 * zoom) {
                ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: 880 * zoom, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28 * zoom)
            .padding(.vertical, 24 * zoom)
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
                .font(.system(size: 14 * zoom))
                .lineSpacing(4 * zoom)
        case let .listItem(indent, marker, text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(marker)
                    .font(.system(size: 14 * zoom, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                Text(inline(text)).font(.system(size: 14 * zoom)).lineSpacing(3 * zoom)
            }
            .padding(.leading, CGFloat(indent) * 20 * zoom)
        case let .quote(text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: 3)
                Text(inline(text))
                    .font(.system(size: 14 * zoom))
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
                        .font(.system(size: 13 * zoom, design: .monospaced))
                        .lineSpacing(3 * zoom)
                        .padding(12 * zoom)
                }
            }
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        case let .table(headers, rows):
            MarkdownTable(headers: headers, rows: rows, zoom: zoom)
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
        case 1: .system(size: 30 * zoom, weight: .bold)
        case 2: .system(size: 24 * zoom, weight: .bold)
        case 3: .system(size: 20 * zoom, weight: .semibold)
        case 4: .system(size: 17 * zoom, weight: .semibold)
        default: .system(size: 15 * zoom, weight: .semibold)
        }
    }
}

private struct MarkdownTable: View {
    let headers: [String]
    let rows: [[String]]
    let zoom: CGFloat

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
                .font(.system(size: 13 * zoom, weight: header ? .semibold : .regular))
                .frame(minWidth: 100 * zoom, maxWidth: 280 * zoom, alignment: .leading)
                .padding(.horizontal, 10 * zoom)
                .padding(.vertical, 8 * zoom)
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
                VStack(alignment: .leading, spacing: 0) {
                    Text("Files")
                        .font(.caption.weight(.semibold))
                    Text(root.lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh files")
                Button(action: close) { Image(systemName: "sidebar.right") }
                    .buttonStyle(.borderless)
                    .help("Close Files (Command-B)")
                    .accessibilityLabel("Close file browser")
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(.thinMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.primary.opacity(0.11), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.035), radius: 2, y: 1)
            .padding(.horizontal, 5)
            .padding(.top, 4)
            .padding(.bottom, 4)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search files", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 6)
            .padding(.bottom, 5)

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
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        // The persisted preference stays at least 188 pt, but the responsive
        // shell may temporarily compress Files to 150 pt at minimum window size.
        .frame(minWidth: 150, maxWidth: .infinity, maxHeight: .infinity)
        .background {
            SidebarBackdropView(appearance: settings.sidebarAppearance)
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
