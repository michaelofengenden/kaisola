import AppKit
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Facts VoiceOver can report without trying to infer what an image depicts.
/// The format and dimensions come from the decoded image source, not its
/// filename, while description text is used only when the file actually stores
/// an authored description.
struct ImagePreviewAccessibilityMetadata: Equatable {
    let filename: String
    let pixelWidth: Int
    let pixelHeight: Int
    let format: String
    let authoredDescription: String?

    init(
        filename: String,
        pixelWidth: Int,
        pixelHeight: Int,
        format: String,
        authoredDescription: String?
    ) {
        self.filename = filename
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.format = format
        self.authoredDescription = authoredDescription?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).nilIfEmpty
    }

    var accessibilityDescription: String {
        let facts = "Image preview: \(filename). \(format) format, "
            + "\(pixelWidth) by \(pixelHeight) pixels."
        if let authoredDescription {
            return facts + " Authored description: \(authoredDescription)"
        }
        return facts + " No authored description is available."
    }

    static func load(from url: URL) -> ImagePreviewAccessibilityMetadata? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
        CGImageSourceGetCount(source) > 0,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
        let pixelWidth = positiveInteger(properties[kCGImagePropertyPixelWidth]),
        let pixelHeight = positiveInteger(properties[kCGImagePropertyPixelHeight]) else {
            return nil
        }

        return ImagePreviewAccessibilityMetadata(
            filename: url.lastPathComponent,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            format: formatName(for: CGImageSourceGetType(source)),
            authoredDescription: authoredDescription(in: properties)
        )
    }

    private static func positiveInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let integer = number.intValue
        return integer > 0 ? integer : nil
    }

    private static func formatName(for typeIdentifier: CFString?) -> String {
        guard let identifier = typeIdentifier as String? else { return "Unknown image" }
        switch identifier {
        case "public.jpeg": return "JPEG"
        case "public.png": return "PNG"
        case "com.compuserve.gif": return "GIF"
        case "public.tiff": return "TIFF"
        case "com.microsoft.bmp": return "BMP"
        case "com.apple.icns": return "ICNS"
        case "com.microsoft.ico": return "ICO"
        case "public.heic": return "HEIC"
        case "public.heif": return "HEIF"
        case "public.avif": return "AVIF"
        case "org.webmproject.webp": return "WebP"
        default:
            return UTType(identifier)?.preferredFilenameExtension?.uppercased()
                ?? "Unknown image"
        }
    }

    private static func authoredDescription(in properties: [CFString: Any]) -> String? {
        let candidates: [(CFString, CFString)] = [
            (kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract),
            (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyPNGDescription),
            (kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment),
        ]
        for (dictionaryKey, valueKey) in candidates {
            guard let dictionary = properties[dictionaryKey] as? [CFString: Any],
                  let value = dictionary[valueKey] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Persistent recovery state for an external-open request that macOS rejected.
/// A failed button press must not look successful merely because the request
/// API returned; only an accepted default-app request or a successful explicit
/// application launch clears the failure for that exact document.
struct FilePreviewExternalOpenState: Equatable {
    private enum Failure: Equatable {
        case defaultApplicationRejected
        case chosenApplicationFailed
    }

    private(set) var failedURL: URL?
    private var failure: Failure?

    var title: String? {
        guard let failedURL else { return nil }
        return "Couldn’t open \(filename(for: failedURL))"
    }

    var detail: String? {
        switch failure {
        case .defaultApplicationRejected:
            "macOS did not accept the request to open this file."
        case .chosenApplicationFailed:
            "The chosen application could not open this file."
        case nil:
            nil
        }
    }

    var revealLabel: String? {
        failedURL.map { "Reveal \(filename(for: $0)) in Finder" }
    }

    var chooseApplicationLabel: String? {
        failedURL.map { "Choose Application for \(filename(for: $0))" }
    }

    mutating func recordDefaultApplicationResult(for url: URL, accepted: Bool) {
        if accepted {
            clearFailure(for: url)
        } else {
            failedURL = url
            failure = .defaultApplicationRejected
        }
    }

    mutating func recordChosenApplicationResult(for url: URL, error: Error?) {
        // The app chooser completes asynchronously. If the user moved to a
        // different document while it was open, its old result cannot revive
        // a banner for the prior file in the replacement preview.
        guard failedURL == url else { return }
        if error == nil {
            clearFailure(for: url)
        } else {
            failure = .chosenApplicationFailed
        }
    }

    mutating func retarget(to url: URL) {
        guard let failedURL, failedURL != url else { return }
        self.failedURL = nil
        failure = nil
    }

    private mutating func clearFailure(for url: URL) {
        guard failedURL == url else { return }
        failedURL = nil
        failure = nil
    }

    private func filename(for url: URL) -> String {
        url.lastPathComponent.nilIfEmpty ?? "this file"
    }
}

/// The complete destructive choice shown before Revert Changes replaces an
/// editor draft. Keeping this value independent of the dialog makes the exact
/// document and recovered-draft warning stable even if surrounding view state
/// refreshes while the confirmation is open.
struct FilePreviewRevertConfirmation: Equatable {
    let fileURL: URL
    let includesRecoveredDraft: Bool

    private var filename: String {
        fileURL.lastPathComponent.nilIfEmpty ?? "this file"
    }

    var title: String { "Revert changes in \(filename)?" }
    var confirmLabel: String { "Revert \(filename)" }

    var message: String {
        if includesRecoveredDraft {
            return "This permanently discards current edits and the recovered draft for "
                + "\(filename). Recovery data is kept until you confirm."
        }
        return "This permanently discards current edits in \(filename). "
            + "Recovery data is kept until you confirm."
    }

    func matchesCurrentDocument(_ url: URL) -> Bool {
        fileURL.standardizedFileURL == url.standardizedFileURL
    }
}

private struct FilePreviewRevertConfirmationModifier: ViewModifier {
    @Binding var confirmation: FilePreviewRevertConfirmation?
    let onConfirm: (FilePreviewRevertConfirmation) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            confirmation?.title ?? "Revert changes?",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmation
        ) { value in
            Button(value.confirmLabel, role: .destructive) { onConfirm(value) }
            Button("Cancel", role: .cancel) {}
        } message: { value in
            Text(value.message)
        }
    }
}

struct FilePreviewEditorControlAccessibility: Equatable {
    enum Kind: Equatable {
        case markdown
        case text
        case html
    }

    let kind: Kind
    let editorVisible: Bool

    var label: String {
        switch (kind, editorVisible) {
        case (.markdown, false): "Edit Markdown source"
        case (.markdown, true): "Show Markdown preview"
        case (.text, false): "Edit text"
        case (.text, true): "Show text preview"
        case (.html, false): "Edit HTML source"
        case (.html, true): "Show HTML preview"
        }
    }

    var value: String {
        switch (kind, editorVisible) {
        case (.markdown, false): "Markdown preview shown"
        case (.markdown, true): "Markdown source editor shown"
        case (.text, false): "Text preview shown"
        case (.text, true): "Text editor shown"
        case (.html, false): "HTML preview shown"
        case (.html, true): "HTML source editor shown"
        }
    }
}

struct FilePreviewSaveControlAccessibility: Equatable {
    let fileURL: URL
    let isDirty: Bool
    let isLoading: Bool
    let isSaving: Bool
    let hasConflict: Bool

    private var filename: String {
        fileURL.lastPathComponent.nilIfEmpty ?? "this file"
    }

    var label: String { "Save \(filename)" }

    var value: String {
        let state: String
        if isSaving { state = "Saving" }
        else if isLoading { state = "Loading document" }
        else if isDirty { state = "Changes pending" }
        else { state = "Saved" }
        return hasConflict ? "\(state), file changed on disk" : state
    }

    var isEnabled: Bool { isDirty && !isLoading && !isSaving }
}

enum FilePreviewControlAccessibility {
    static let headerFocusOrder = [
        "preview.editorMode",
        "preview.save",
        "preview.options",
        "preview.hide",
    ]
}

/// File preview/editor pane: UTF-8 text is editable with ⌘S save + revert,
/// markdown renders styled (with a raw-source toggle), images display, and
/// binary/oversized files degrade to a clear notice.
struct FilePreviewView: View {
    let url: URL
    /// Project root grants HTML previews access to their own relative assets
    /// (styles, scripts, images) without granting the rest of the filesystem.
    let workspaceRoot: URL?
    /// One-based line target from terminal/chat file links and restored tabs.
    let targetLine: Int?
    let tabs: [AppModel.FileWorkbenchTab]
    let selectTab: (URL) -> Void
    let setTabPinned: (URL, Bool) -> Void
    let closeTab: (URL) -> Void
    let canReopenClosedTab: Bool
    let reopenClosedTab: () -> Void
    let commandScopeID: ObjectIdentifier?
    let navigationCommitted: (URL) -> Void
    /// Restores AppModel's selection when a pending file switch is cancelled.
    let restoreSelection: (URL) -> Void
    /// Hides the whole preview column non-destructively (the toggle-document
    /// path): tabs and the current file stay remembered for reopen. `close`
    /// remains the destructive per-document door.
    let hide: () -> Void
    let close: () -> Void
    private let recoveryStore: FilePreviewRecoveryStore
    /// The file tree already watches the project for agent edits. The mounted
    /// document needs its own subscriber because the rail may be hidden while
    /// an agent rewrites the file currently under review.
    @StateObject private var workspaceWatcher: WorkspaceWatcher

    init(
        url: URL,
        workspaceRoot: URL?,
        targetLine: Int? = nil,
        tabs: [AppModel.FileWorkbenchTab] = [],
        selectTab: @escaping (URL) -> Void = { _ in },
        setTabPinned: @escaping (URL, Bool) -> Void = { _, _ in },
        closeTab: @escaping (URL) -> Void = { _ in },
        canReopenClosedTab: Bool = false,
        reopenClosedTab: @escaping () -> Void = {},
        commandScopeID: ObjectIdentifier? = nil,
        navigationCommitted: @escaping (URL) -> Void = { _ in },
        restoreSelection: @escaping (URL) -> Void,
        hide: @escaping () -> Void,
        close: @escaping () -> Void,
        recoveryStore: FilePreviewRecoveryStore = FilePreviewRecoveryStore()
    ) {
        self.url = url
        self.workspaceRoot = workspaceRoot
        self.targetLine = targetLine
        self.tabs = tabs
        self.selectTab = selectTab
        self.setTabPinned = setTabPinned
        self.closeTab = closeTab
        self.canReopenClosedTab = canReopenClosedTab
        self.reopenClosedTab = reopenClosedTab
        self.commandScopeID = commandScopeID
        self.navigationCommitted = navigationCommitted
        self.restoreSelection = restoreSelection
        self.hide = hide
        self.close = close
        self.recoveryStore = recoveryStore
        _workspaceWatcher = StateObject(
            wrappedValue: WorkspaceWatcher(
                root: workspaceRoot ?? url.deletingLastPathComponent()
            )
        )
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.undoManager) private var undoManager

    @State private var content: FilePreviewContent = .unreadable
    @State private var draft = ""
    @State private var savedText = ""
    @State private var richDraft = NSAttributedString(string: "")
    @State private var savedRichText = NSAttributedString(string: "")
    @State private var pdfDocument: PDFDocument?
    @State private var showMarkdownSource = false
    /// Text (non-markdown) files default to a read-only, syntax-highlighted
    /// view; this toggle enters the confined CodeMirror source editor.
    @State private var isEditingText = false
    /// Cached highlighted rendering of `draft`, recomputed only when the source,
    /// language, or appearance changes (never on every keystroke, and never on
    /// a zoom step — the reader owns the font).
    @State private var highlightedSource = AttributedSource(value: NSAttributedString())
    /// Shared by the reader and the editor so the read/edit toggle keeps the
    /// same line at the top of the viewport.
    @State private var textScrollMemory = FilePreviewTextScrollMemory()
    @State private var previewNotice: FilePreviewNotice?
    @State private var externalOpen = FilePreviewExternalOpenState()
    @State private var revertConfirmation: FilePreviewRevertConfirmation?
    /// The URL that produced the currently rendered draft. It deliberately
    /// stays unchanged while another URL loads, so Save can never target the
    /// incoming file with the outgoing file's contents.
    @State private var loadedURL: URL?
    @State private var loadingURL: URL?
    @State private var loadedModificationDate: Date?
    /// A navigation/close blocked on unsaved changes, awaiting the user.
    @State private var pendingAction: PendingAction?
    /// True when Markdown navigation is waiting for the latest autosave rather
    /// than a user decision. A save already in flight may have captured an
    /// older draft, so its completion can chain one final save before loading.
    @State private var autosavePendingAction = false
    @State private var showUnsavedPrompt = false
    @State private var showExternalChangePrompt = false
    /// Collapsible, never dismissible: the banner can fold into a header
    /// indicator, but only reloading, saving through the conflict decision, or
    /// discarding the draft clears the conflict.
    @State private var conflict = FilePreviewConflictState()
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var loadTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var markdownAutosaveTask: Task<Void, Never>?
    @State private var highlightTask: Task<Void, Never>?
    @State private var outlineTask: Task<Void, Never>?
    @State private var outlineItems: [SourceOutlineItem] = []
    @State private var outlineTargetLine: Int?
    @State private var outlineNavigationRevision: UInt64 = 0
    @State private var recoveryJournalTask: Task<Void, Never>?
    @State private var documentZoom: CGFloat = 1
    @State private var previewRevision = 0
    @State private var richDocumentCommand: RichDocumentCommand?
    /// A recovered draft may equal an empty fallback baseline when the disk
    /// file is temporarily unreadable. Keep it dirty until an explicit save or
    /// discard even in that edge case.
    @State private var recoveredDraftPending = false
    /// A claim the store refused. The draft is still journaled, so the banner
    /// keeps it visible with retry, inspect, and discard instead of letting the
    /// load pretend nothing was ever stored.
    @State private var recoveryClaimFailure: FilePreviewRecoveryClaimFailure?
    @State private var showRecoveryDiscardPrompt = false
    @State private var recoveryOwnerID = UUID().uuidString.lowercased()
    @State private var recoveryRevision: UInt64 = 0
    @State private var recoveryFencedRevision: UInt64 = 0
    @State private var recoveryFencedSourceTokens: [FilePreviewRecoveryToken] = []
    @State private var recoveryFenceToken: FilePreviewRecoveryToken?
    @State private var recoveryGeneration: UInt64 = 0
    @State private var pendingEditedPreviewPromotion: URL?
    @State private var hoveredTabURL: URL?
    @State private var ownedRecoveryToken: FilePreviewRecoveryToken?
    @State private var claimedRecoverySourceTokens: [FilePreviewRecoveryToken] = []
    @State private var lastRecoverableRichDraft = NSAttributedString(string: "")

    private enum PendingAction: Equatable {
        case navigate(URL)
        case close
        case hide
    }

    private var isDirty: Bool {
        if recoveredDraftPending { return true }
        if case .docx = content { return !richDraft.isEqual(to: savedRichText) }
        return draft != savedText
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if externalOpen.failedURL != nil {
                externalOpenFailureBanner
                Divider()
            }
            if let previewNotice {
                noticeBanner(previewNotice)
                Divider()
            }
            if let recoveryClaimFailure {
                recoveryFailureBanner(recoveryClaimFailure)
                Divider()
            }
            if conflict.showsBanner {
                externalChangeBanner
                Divider()
            }
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
        .clipShape(RoundedRectangle(cornerRadius: KaisolaVisualSystem.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: KaisolaVisualSystem.panelRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.8)
        }
        .onAppear {
            FilePreviewRecoveryOwnerRegistry.shared.register(recoveryOwnerID)
            beginLoad(url)
        }
        .onChange(of: url) { _, newURL in
            guard newURL != loadedURL, newURL != loadingURL else { return }
            switch FilePreviewNavigationPolicy.requestDecision(
                isDirty: isDirty,
                isMarkdown: isMarkdownContent,
                isSaving: isSaving,
                hasExternalConflict: conflict.isActive || showExternalChangePrompt
            ) {
            case .navigate:
                beginLoad(newURL)
            case .autosave:
                pendingAction = .navigate(newURL)
                autosavePendingAction = true
                markdownAutosaveTask?.cancel()
                save(advancePendingAction: true, silently: true)
            case .awaitCurrentSave:
                pendingAction = .navigate(newURL)
                autosavePendingAction = true
                markdownAutosaveTask?.cancel()
            case .prompt:
                pendingAction = .navigate(newURL)
                autosavePendingAction = false
                showUnsavedPrompt = true
            }
        }
        .onChange(of: targetLine) { _, newLine in
            guard newLine != nil else { return }
            outlineTargetLine = nil
            outlineNavigationRevision &+= 1
            if case .text = content { isEditingText = true }
            if case .html = content { isEditingText = true }
            if case .markdown = content { showMarkdownSource = false }
        }
        // Re-highlight when appearance flips or when returning to read mode with
        // edited (or reverted/discarded) text. Skipped while editing so typing
        // never pays the highlight cost.
        .onChange(of: colorScheme) { _, _ in refreshHighlight() }
        .onChange(of: isEditingText) { _, editing in if !editing { refreshHighlight() } }
        .onChange(of: draft) { oldValue, newValue in
            guard FilePreviewDraftBounds.acceptsText(newValue) else {
                draft = oldValue
                reportOversizedDraft()
                return
            }
            // Markdown never renders the highlighted source, so re-highlighting
            // the whole file on every keystroke was pure cost — and on a long
            // document it was cost paid while the user was typing into it.
            if !isEditingText, !isMarkdownContent { refreshHighlight() }
            scheduleOutlineRefresh()
            if draft == savedText, !recoveredDraftPending, let loadedURL {
                clearRecoveryTokens(for: loadedURL)
            }
            scheduleRecoveryJournal()
            scheduleMarkdownAutosave()
            promoteEditedPreviewIfNeeded()
        }
        .onChange(of: richDraft) { oldValue, newValue in
            guard FilePreviewDraftBounds.acceptsRichText(newValue) else {
                richDraft = oldValue
                reportOversizedDraft()
                return
            }
            scheduleRecoveryJournal()
            promoteEditedPreviewIfNeeded()
        }
        .onChange(of: recoveredDraftPending) { _, _ in promoteEditedPreviewIfNeeded() }
        .onChange(of: workspaceWatcher.changeToken) { _, _ in
            reconcileExternalFileChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kaisolaFlushFilePreviews)) { _ in
            flushPendingPreviewSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kaisolaCloseActiveFileTab)) { notification in
            guard let commandScopeID,
                  let requestOwner = notification.object as AnyObject?,
                  ObjectIdentifier(requestOwner) == commandScopeID else { return }
            requestClose()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kaisolaPrepareWorkspaceFileMutation)) { notification in
            guard let request = notification.object as? WorkspaceFileMutationBarrierRequest,
                  let loadedURL,
                  WorkspaceFileOperations.contains(loadedURL, in: request.item) else { return }
            flushPendingPreviewSave()
            if isDirty || isSaving || showExternalChangePrompt {
                request.block()
            }
        }
        .onDisappear {
            flushPendingPreviewSave()
            loadTask?.cancel()
            markdownAutosaveTask?.cancel()
            highlightTask?.cancel()
            outlineTask?.cancel()
            recoveryJournalTask?.cancel()
            releaseRecoveryClaims()
            FilePreviewRecoveryOwnerRegistry.shared.unregister(recoveryOwnerID)
        }
        .confirmationDialog(
            "Unsaved changes",
            isPresented: $showUnsavedPrompt
        ) {
            Button("Save") {
                autosavePendingAction = false
                save(advancePendingAction: true)
            }
            Button("Discard Changes", role: .destructive) {
                if let loadedURL, !clearRecoveryTokens(for: loadedURL) { return }
                draft = savedText
                richDraft = savedRichText
                recoveredDraftPending = false
                conflict.apply(.draftDiscarded)
                completePendingAction()
            }
            Button("Cancel", role: .cancel) {
                autosavePendingAction = false
                pendingAction = nil
                if let loadedURL { restoreSelection(loadedURL) }
            }
        } message: {
            Text("\(loadedURL?.lastPathComponent ?? "This file") has unsaved changes.")
        }
        .confirmationDialog("File changed on disk", isPresented: $showExternalChangePrompt) {
            Button("Reload from Disk") {
                autosavePendingAction = false
                pendingAction = nil
                if let loadedURL {
                    guard clearRecoveryTokens(for: loadedURL) else { return }
                    beginLoad(loadedURL)
                }
            }
            Button("Overwrite", role: .destructive) {
                autosavePendingAction = false
                save(force: true, advancePendingAction: pendingAction != nil)
            }
            Button("Cancel", role: .cancel) {
                autosavePendingAction = false
                if let loadedURL { restoreSelection(loadedURL) }
                pendingAction = nil
            }
        } message: {
            Text("An agent or another app edited this file after it was opened. Reload it or explicitly overwrite the newer version.")
        }
        .confirmationDialog(
            "Discard the unrecovered draft?",
            isPresented: $showRecoveryDiscardPrompt
        ) {
            Button("Discard Draft", role: .destructive) { discardUnrecoveredDrafts() }
            Button("Keep Draft", role: .cancel) {}
        } message: {
            Text("The stored draft for \(loadedURL?.lastPathComponent ?? url.lastPathComponent) is deleted. Drafts for every other file are left alone.")
        }
        .modifier(
            FilePreviewRevertConfirmationModifier(
                confirmation: $revertConfirmation,
                onConfirm: performConfirmedRevert
            )
        )
    }

    private func completePendingAction() {
        let action = pendingAction
        pendingAction = nil
        autosavePendingAction = false
        switch action {
        case let .navigate(next):
            beginLoad(next)
        case .close:
            close()
        case .hide:
            hide()
        case nil:
            break
        }
    }

    private func requestClose() {
        if isDirty {
            pendingAction = .close
            autosavePendingAction = false
            showUnsavedPrompt = true
        } else {
            close()
        }
    }

    /// Same dirty guard as `requestClose`: hiding unmounts this view, so an
    /// unsaved draft gets the save/discard/cancel prompt before the column
    /// disappears rather than relying on recovery alone.
    private func requestHide() {
        if isDirty {
            pendingAction = .hide
            autosavePendingAction = false
            showUnsavedPrompt = true
        } else {
            hide()
        }
    }

    private var externalChangeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(KaisolaStatusTone.needsYou.foregroundColor)
                .accessibilityHidden(true)
            Text("Changed on disk while you were editing")
                .font(.caption.weight(.medium))
            Spacer(minLength: 8)
            Button("Reload") {
                reloadExternalVersion()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            // Collapsing folds the banner into the header indicator. There is
            // deliberately no dismissal: the conflict outlives the banner.
            Button {
                conflict.apply(.collapseRequested)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .help("Collapse to a compact conflict indicator")
            .accessibilityLabel("Collapse changed-on-disk notice")
            .accessibilityIdentifier("preview.conflictCollapse")
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 32)
        .background(Color.orange.opacity(colorScheme == .dark ? 0.12 : 0.08))
        .accessibilityElement(children: .contain)
    }

    /// A claim the recovery store refused is presented as a choice, never as a
    /// silent loss. Retry re-runs the load and inspect reveals the exact stored
    /// record; only the explicit discard removes anything, so the banner never
    /// writes over the journal it is reporting on.
    private func recoveryFailureBanner(_ failure: FilePreviewRecoveryClaimFailure) -> some View {
        let retryable = FilePreviewRecoveryFailurePolicy.canRetry(
            isDirty: isDirty,
            isLoading: isLoading,
            isSaving: isSaving
        )
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: FilePreviewNotice.Severity.error.systemImageName)
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Could not check for an unsaved draft")
                    .font(.caption.weight(.medium))
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button("Retry") { retryRecoveryClaim() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!retryable)
                .help(retryable
                    ? "Look for the stored draft again"
                    : "Save or discard your current edits before retrying")
            Button("Inspect") { inspectRecoveryJournal() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reveal the stored recovery record in Finder")
            Button("Discard", role: .destructive) { showRecoveryDiscardPrompt = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Delete the stored draft for this file")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(minHeight: 32)
        .background(Color.red.opacity(colorScheme == .dark ? 0.13 : 0.08))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error: \(failure.message)")
    }

    /// The failed attempt never modified the journal, so a retry is just the
    /// ordinary load again, including its restore, notice, and dirty-state
    /// bookkeeping.
    private func retryRecoveryClaim() {
        guard recoveryClaimFailure != nil, let loadedURL else { return }
        guard FilePreviewRecoveryFailurePolicy.canRetry(
            isDirty: isDirty,
            isLoading: isLoading,
            isSaving: isSaving
        ) else { return }
        recoveryClaimFailure = nil
        beginLoad(loadedURL)
    }

    private func inspectRecoveryJournal() {
        let target = loadedURL ?? url
        let reveal = recoveryStore.newestOrphanRecordURL(
            for: target,
            workspaceRoot: workspaceRoot
        ) ?? recoveryStore.directoryURL
        guard FileManager.default.fileExists(atPath: reveal.path) else {
            ToastCenter.shared.show(
                "The recovery record is no longer on disk.",
                style: .error
            )
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([reveal])
    }

    private func discardUnrecoveredDrafts() {
        let target = loadedURL ?? url
        do {
            try recoveryStore.discardOrphans(for: target, workspaceRoot: workspaceRoot)
            recoveryClaimFailure = nil
        } catch {
            handleRecoveryFailure(error, richDocument: false)
        }
    }

    private func noticeBanner(_ notice: FilePreviewNotice) -> some View {
        let tint: Color = switch notice.severity {
        case .information: .accentColor
        case .warning: .orange
        case .error: .red
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: notice.severity.systemImageName)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(notice.message)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityLabel(notice.accessibilityLabel)
            Spacer(minLength: 8)
            Button {
                previewNotice = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss notice")
            .accessibilityLabel("Dismiss preview notice")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(minHeight: 32)
        .background(tint.opacity(colorScheme == .dark ? 0.13 : 0.08))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var externalOpenFailureBanner: some View {
        if let title = externalOpen.title,
           let detail = externalOpen.detail,
           let revealLabel = externalOpen.revealLabel,
           let chooseApplicationLabel = externalOpen.chooseApplicationLabel {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button("Reveal in Finder", action: revealExternalOpenFailureInFinder)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(revealLabel)
                Button("Choose Application…", action: chooseApplicationForExternalOpen)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(chooseApplicationLabel)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(minHeight: 32)
            .background(Color.red.opacity(colorScheme == .dark ? 0.13 : 0.08))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Error: \(title). \(detail)")
        }
    }

    /// FSEvents is project-wide, so re-check the exact mounted file before
    /// acting. Clean previews follow agent writes automatically; dirty editors
    /// retain the user's draft and show a reversible reload choice.
    private func reconcileExternalFileChange() {
        guard !isLoading, !isSaving, let loadedURL,
              FilePreviewDiskState.changed(onDisk: loadedURL, since: loadedModificationDate) else {
            return
        }
        conflict.apply(.detectedExternalChange(isDirty: isDirty))
        if !isDirty { beginLoad(loadedURL) }
    }

    private func reloadExternalVersion() {
        guard let loadedURL else { return }
        guard clearRecoveryTokens(for: loadedURL) else { return }
        conflict.apply(.reloaded)
        recoveredDraftPending = false
        beginLoad(loadedURL)
    }

    private var header: some View {
        HStack(spacing: 7) {
            documentTabs
            if tabs.isEmpty, isDirty {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    .accessibilityLabel("Unsaved changes")
            }
            if isLoading || isSaving { ProgressView().controlSize(.mini) }
            if !outlineItems.isEmpty {
                outlineMenu
            }
            if case .markdown = content {
                let accessibility = FilePreviewEditorControlAccessibility(
                    kind: .markdown,
                    editorVisible: showMarkdownSource
                )
                Button { showMarkdownSource.toggle() } label: {
                    Image(systemName: showMarkdownSource ? "doc.richtext.fill" : "pencil")
                }
                .buttonStyle(.borderless)
                .help(showMarkdownSource ? "Show formatted Markdown" : "Edit Markdown")
                .accessibilityLabel(accessibility.label)
                .accessibilityValue(accessibility.value)
                .accessibilityIdentifier("preview.editorMode")
            } else if case .text = content {
                editModeButton(kind: .text, help: "Edit text")
            } else if case .html = content {
                editModeButton(kind: .html, help: "Edit HTML source")
            }
            if conflict.showsCompactIndicator {
                Button {
                    conflict.apply(.expandRequested)
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(KaisolaStatusTone.needsYou.foregroundColor)
                }
                .buttonStyle(.borderless)
                .help("Changed on disk — show reload options")
                .accessibilityLabel("Changed on disk, show reload options")
                .accessibilityIdentifier("preview.conflictIndicator")
            }
            if isEditable {
                let accessibility = FilePreviewSaveControlAccessibility(
                    fileURL: loadedURL ?? url,
                    isDirty: isDirty,
                    isLoading: isLoading,
                    isSaving: isSaving,
                    hasConflict: conflict.isActive
                )
                Button { save() } label: {
                    Image(systemName: "square.and.arrow.down")
                        // Tinted only under a conflict; otherwise the control
                        // keeps the header's ordinary borderless styling.
                        .foregroundStyle(
                            conflict.isActive
                                ? AnyShapeStyle(KaisolaStatusTone.needsYou.foregroundColor)
                                : AnyShapeStyle(.foreground)
                        )
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!accessibility.isEnabled)
                .help(conflict.saveHelpText)
                .accessibilityLabel(accessibility.label)
                .accessibilityValue(accessibility.value)
                .accessibilityIdentifier("preview.save")
            }
            previewOptionsMenu
            Button {
                requestHide()
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .help("Hide Document")
            .accessibilityLabel("Hide Document")
            .accessibilityIdentifier("preview.hide")
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var documentTabs: some View {
        if tabs.isEmpty {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text((loadingURL ?? loadedURL ?? url).lastPathComponent)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        } else {
            ScrollViewReader { tabScroll in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tabs) { tab in
                            let normalizedURL = tab.url.standardizedFileURL
                            let selected = normalizedURL == url.standardizedFileURL
                            let modified = FilePreviewTabPolicy.isModified(
                                tab,
                                loadedURL: loadedURL,
                                isDirty: isDirty
                            )
                            let displayTitle = FilePreviewTabPolicy.displayTitle(
                                for: tab,
                                among: tabs,
                                workspaceRoot: workspaceRoot
                            )
                            let closeVisible = selected
                                || hoveredTabURL?.standardizedFileURL == normalizedURL
                            HStack(spacing: 0) {
                                Button {
                                    selectTab(tab.url)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: tab.isPinned ? "doc.fill" : "doc")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                                        Text(displayTitle)
                                            .font(.caption.weight(selected ? .semibold : .regular))
                                            .italic(!tab.isPinned)
                                            .lineLimit(1)
                                        if modified {
                                            Circle()
                                                .fill(Color.accentColor)
                                                .frame(width: 6, height: 6)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    .padding(.leading, 8)
                                    .padding(.trailing, 3)
                                }
                                .buttonStyle(.plain)
                                .simultaneousGesture(
                                    TapGesture(count: 2).onEnded {
                                        setTabPinned(tab.url, true)
                                    }
                                )
                                .accessibilityLabel(
                                    "\(displayTitle), \(tab.isPinned ? "kept open" : "preview")"
                                        + "\(modified ? ", modified" : "")"
                                )

                                Button {
                                    if selected { requestClose() }
                                    else { closeTab(tab.url) }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .semibold))
                                        .frame(width: 18, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .opacity(closeVisible ? 1 : 0)
                                .allowsHitTesting(closeVisible)
                                .accessibilityHidden(!closeVisible)
                                .accessibilityLabel("Close \(displayTitle)")
                            }
                            .frame(height: 26)
                            .background(
                                selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(
                                        selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06),
                                        lineWidth: 0.7
                                    )
                            }
                            .onHover { hovering in
                                if hovering {
                                    hoveredTabURL = normalizedURL
                                } else if hoveredTabURL?.standardizedFileURL == normalizedURL {
                                    hoveredTabURL = nil
                                }
                            }
                            .contextMenu {
                                Button(tab.isPinned ? "Make Transient" : "Keep Open") {
                                    setTabPinned(tab.url, !tab.isPinned)
                                }
                                .disabled(selected && modified && tab.isPinned)
                                Button("Close") {
                                    if selected { requestClose() }
                                    else { closeTab(tab.url) }
                                }
                                Divider()
                                Button("Reopen Closed Tab") {
                                    reopenClosedTab()
                                }
                                .disabled(!canReopenClosedTab)
                            }
                            .help(tab.isPinned ? tab.url.path : "Preview — double-click to keep open\n\(tab.url.path)")
                            .id(normalizedURL)
                        }
                    }
                }
                .onAppear {
                    tabScroll.scrollTo(url.standardizedFileURL, anchor: .center)
                }
                .onChange(of: url.standardizedFileURL) { _, selectedURL in
                    withAnimation(.easeOut(duration: 0.16)) {
                        tabScroll.scrollTo(selectedURL, anchor: .center)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func editModeButton(
        kind: FilePreviewEditorControlAccessibility.Kind,
        help: String
    ) -> some View {
        let accessibility = FilePreviewEditorControlAccessibility(
            kind: kind,
            editorVisible: isEditingText
        )
        return Button { isEditingText.toggle() } label: {
            Image(systemName: isEditingText ? "eye" : "pencil")
        }
        .buttonStyle(.borderless)
        .help(isEditingText ? "Show preview" : help)
        .accessibilityLabel(accessibility.label)
        .accessibilityValue(accessibility.value)
        .accessibilityIdentifier("preview.editorMode")
    }

    private var outlineMenu: some View {
        Menu {
            ForEach(outlineItems) { item in
                Button {
                    navigate(to: item)
                } label: {
                    Label(
                        outlineTitle(for: item),
                        systemImage: item.kind.systemImage
                    )
                }
            }
        } label: {
            Image(systemName: "list.bullet.indent")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Jump to a symbol or heading")
        .accessibilityLabel("Document outline")
    }

    private func outlineTitle(for item: SourceOutlineItem) -> String {
        let indentation = String(repeating: "\u{2003}", count: max(0, min(5, item.depth - 1)))
        return "\(indentation)\(item.title) — line \(item.line)"
    }

    private func navigate(to item: SourceOutlineItem) {
        outlineTargetLine = item.line
        outlineNavigationRevision &+= 1
        switch content {
        case .markdown:
            // The rendered document is itself a text editor now, so jumping to
            // a heading no longer has to drop the reader into raw source.
            break
        case .text, .html:
            isEditingText = true
        default:
            break
        }
    }

    private var previewOptionsMenu: some View {
        Menu {
            Section("File") {
                Button("Reveal in Finder") {
                    revealCurrentFileInFinder()
                }
                Button("Copy Contents") {
                    copyCurrentFileContents()
                }
                .disabled(copyableContents == nil)
                Button("Open Externally") {
                    openCurrentFileExternally()
                }
            }
            if case .docx = content {
                Section("Format") {
                    Button("Bold") { richDocumentCommand = RichDocumentCommand(kind: .bold) }
                    Button("Italic") { richDocumentCommand = RichDocumentCommand(kind: .italic) }
                    Button("Underline") { richDocumentCommand = RichDocumentCommand(kind: .underline) }
                    Button("Heading") { richDocumentCommand = RichDocumentCommand(kind: .heading) }
                    Button("Bulleted List") { richDocumentCommand = RichDocumentCommand(kind: .bulletList) }
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
                    revertConfirmation = FilePreviewRevertConfirmation(
                        fileURL: loadedURL ?? url,
                        includesRecoveredDraft: recoveredDraftPending
                    )
                }
                .disabled(!isDirty)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Document options")
        .accessibilityLabel("Document options")
        .accessibilityIdentifier("preview.options")
    }

    private var copyableContents: String? {
        switch content {
        case .text, .markdown, .html:
            draft
        case let .csv(text), let .json(text):
            text
        case .docx:
            richDraft.string
        case .pdf, .image, .tooLarge, .binary, .unreadable:
            nil
        }
    }

    private func copyCurrentFileContents() {
        guard let copyableContents else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(copyableContents, forType: .string) else {
            ToastCenter.shared.show("Could not copy file contents", style: .error)
            return
        }
        ToastCenter.shared.show("Copied \((loadedURL ?? url).lastPathComponent)", style: .success)
    }

    /// Reveal the file, or the nearest folder that is actually there.
    ///
    /// `activateFileViewerSelecting` with a path that does not exist opens
    /// Finder selecting nothing, which reads exactly like a broken button —
    /// and this tab can be showing a file that was moved, deleted, or cited by
    /// a name that never resolved. Landing in the containing folder is a real
    /// answer; a blank Finder window is not.
    private func revealCurrentFileInFinder() {
        let target = loadedURL ?? url
        guard let reachable = TerminalFileLinkResolver.revealTarget(for: target) else {
            ToastCenter.shared.show(
                "\(target.lastPathComponent) isn’t on disk any more.",
                style: .error
            )
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([reachable])
    }

    private func openCurrentFileExternally() {
        let target = loadedURL ?? url
        externalOpen.recordDefaultApplicationResult(
            for: target,
            accepted: NSWorkspace.shared.open(target)
        )
    }

    private func performConfirmedRevert(_ confirmation: FilePreviewRevertConfirmation) {
        let target = loadedURL ?? url
        guard confirmation.matchesCurrentDocument(target) else {
            ToastCenter.shared.show(
                "The selected document changed. No edits were reverted.",
                style: .error
            )
            return
        }
        // Under an unresolved conflict the saved file is the newer disk
        // version, so the confirmed revert reloads that rather than leaving a
        // stale buffer behind an indicator that just cleared.
        guard !conflict.isActive else {
            reloadExternalVersion()
            return
        }
        // This is deliberately the first recovery-store mutation in the
        // Revert path. Opening or cancelling the dialog leaves every token and
        // recovered draft byte intact.
        if let loadedURL, !clearRecoveryTokens(for: loadedURL) { return }
        if case .docx = content { richDraft = savedRichText }
        else { draft = savedText }
        recoveredDraftPending = false
    }

    private func revealExternalOpenFailureInFinder() {
        guard let target = externalOpen.failedURL,
              let reachable = TerminalFileLinkResolver.revealTarget(for: target) else {
            ToastCenter.shared.show("The file is no longer on disk.", style: .error)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([reachable])
    }

    private func chooseApplicationForExternalOpen() {
        guard let target = externalOpen.failedURL else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.message = "Choose an application to open \(target.lastPathComponent)."
        panel.prompt = "Open"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let applicationURL = panel.url else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open(
                [target],
                withApplicationAt: applicationURL,
                configuration: configuration
            ) { _, error in
                Task { @MainActor in
                    externalOpen.recordChosenApplicationResult(for: target, error: error)
                }
            }
        }
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

    private var isMarkdownContent: Bool {
        if case .markdown = content { return true }
        return false
    }

    private var previewParseIdentity: PreviewParseIdentity {
        PreviewParseIdentity(
            path: (loadedURL ?? url).standardizedFileURL.path,
            modificationDate: loadedModificationDate,
            revision: previewRevision
        )
    }

    @ViewBuilder
    private func body(for content: FilePreviewContent) -> some View {
        switch content {
        case .text:
            if isEditingText {
                editor
            } else {
                SourceTextReader(
                    source: highlightedSource.value,
                    fontSize: 13 * documentZoom,
                    documentID: (loadedURL ?? url).path,
                    scrollMemory: textScrollMemory
                )
            }
        case .markdown:
            if showMarkdownSource {
                editor
            } else {
                // One continuous document rather than a rendered stack whose
                // blocks were swapped for an editor one at a time. Editing is
                // source-faithful for a stronger reason than before: the text
                // view holds the file's exact Markdown, so there is no
                // structural write-back path that could round-trip a table,
                // task list, or relative image through a lossy serializer.
                MarkdownDocumentView(
                    source: $draft,
                    documentURL: loadedURL ?? url,
                    workspaceRoot: workspaceRoot,
                    imageRevision: workspaceWatcher.changeToken,
                    zoom: $documentZoom,
                    onError: { previewNotice = .error($0) },
                    scrollMemory: textScrollMemory,
                    targetLine: outlineTargetLine ?? targetLine,
                    navigationRevision: outlineNavigationRevision,
                    automaticallyFocus: ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1"
                        && [
                            "preview-edit",
                            "preview-dirty-tab",
                            "preview-table-edit",
                        ].contains(ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"] ?? "")
                )
            }
        case .image:
            let imageURL = loadedURL ?? url
            if let image = NSImage(contentsOf: imageURL) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 1200 * documentZoom)
                        .padding(16)
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isImage)
                        .accessibilityLabel(
                            ImagePreviewAccessibilityMetadata.load(from: imageURL)?
                                .accessibilityDescription
                                ?? "Image preview: \(imageURL.lastPathComponent). "
                                    + "Image format, pixel dimensions, and any authored "
                                    + "description are unavailable."
                        )
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                ContentUnavailableView("Could not load image", systemImage: "photo")
            }
        case let .csv(text):
            CsvPreview(text: text, identity: previewParseIdentity)
        case let .json(text):
            JsonPreview(text: text, identity: previewParseIdentity)
        case .html:
            if isEditingText {
                editor
            } else {
                HtmlFilePreview(
                    fileURL: loadedURL ?? url,
                    readAccessRoot: workspaceRoot,
                    source: draft,
                    identity: previewParseIdentity,
                    zoom: documentZoom,
                    contentRevision: previewRevision
                )
            }
        case .docx:
            RichDocumentEditor(text: $richDraft, zoom: documentZoom, command: richDocumentCommand)
                .background(Color(nsColor: .underPageBackgroundColor))
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor))
        case .pdf:
            if let pdfDocument {
                PDFFilePreview(document: pdfDocument)
            } else {
                unavailablePreview(
                    title: "Could not load PDF",
                    systemImage: "doc.richtext",
                    description: "The document may be damaged, encrypted, or incomplete."
                )
            }
        case let .tooLarge(size):
            unavailablePreview(
                title: "File too large to preview",
                systemImage: "doc.zipper",
                description: "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) — bounded previews keep the project responsive."
            )
        case .binary:
            unavailablePreview(
                title: "Binary file",
                systemImage: "doc",
                description: "No text preview is available in Kaisola."
            )
        case .unreadable:
            unavailablePreview(
                title: "Could not read file",
                systemImage: "exclamationmark.triangle",
                description: "The file may have moved or its permissions may have changed."
            )
        }
    }

    private func unavailablePreview(
        title: String,
        systemImage: String,
        description: String
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            HStack {
                Button("Reveal in Finder", action: revealCurrentFileInFinder)
                Button("Open Externally") {
                    openCurrentFileExternally()
                }
            }
        }
    }

    private var editor: some View {
        Group {
            if let editableMarkdownURL {
                // Markdown retains the native whole-source editor because its
                // image import and magnification bridge is intentionally tied
                // to a project-confined NSView. Ordinary source files use the
                // networkless CodeMirror island below.
                LineTargetTextEditor(
                    text: $draft,
                    fontSize: 13,
                    targetLine: editorTargetLine,
                    navigationRevision: outlineNavigationRevision,
                    documentID: editableMarkdownURL.path,
                    markdownURL: editableMarkdownURL,
                    workspaceRoot: workspaceRoot,
                    onError: { previewNotice = .error($0) },
                    magnification: documentZoom,
                    onMagnificationChanged: { documentZoom = $0 },
                    scrollMemory: textScrollMemory
                )
            } else {
                CodeEditorView(
                    text: $draft,
                    fileURL: loadedURL ?? url,
                    targetLine: editorTargetLine,
                    navigationRevision: outlineNavigationRevision,
                    fontSize: 13 * documentZoom,
                    colorScheme: colorScheme,
                    undoManager: undoManager,
                    scrollMemory: textScrollMemory,
                    onError: { previewNotice = .error($0) }
                )
            }
        }
    }

    private var editableMarkdownURL: URL? {
        guard case .markdown = content else { return nil }
        return loadedURL ?? url
    }

    private var editorTargetLine: Int? {
        outlineTargetLine ?? targetLine
    }

    private func beginLoad(_ target: URL) {
        loadTask?.cancel()
        markdownAutosaveTask?.cancel()
        highlightTask?.cancel()
        outlineTask?.cancel()
        recoveryJournalTask?.cancel()
        recoveryGeneration &+= 1
        releaseRecoveryClaims()
        loadingURL = target
        externalOpen.retarget(to: target)
        isLoading = true
        previewNotice = nil
        outlineItems = []
        outlineTargetLine = nil
        outlineNavigationRevision &+= 1
        conflict.apply(.documentLoaded)
        recoveredDraftPending = false
        recoveryClaimFailure = nil
        ownedRecoveryToken = nil
        claimedRecoverySourceTokens = []
        recoveryRevision = 0
        recoveryFencedRevision = 0
        recoveryFencedSourceTokens = []
        recoveryFenceToken = nil
        pendingEditedPreviewPromotion = nil
        let root = workspaceRoot
        let store = recoveryStore
        let ownerID = recoveryOwnerID
        loadTask = Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                FilePreviewSnapshot(
                    content: FilePreviewContent.load(url: target),
                    modificationDate: FilePreviewDiskState.modificationDate(of: target),
                    recoveryOutcome: store.claimOutcome(
                        for: target,
                        workspaceRoot: root,
                        claimantID: ownerID
                    )
                )
            }.value
            let recovery = snapshot.recoveryClaim?.record
            let rich: RichDocumentPayload?
            if case .docx = snapshot.content {
                rich = await RichDocumentWorker.shared.load(url: target)
            } else {
                rich = nil
            }
            let pdf: PDFDocumentPayload?
            if case .pdf = snapshot.content {
                pdf = await PDFDocumentWorker.shared.load(url: target)
            } else {
                pdf = nil
            }
            let recoveredRich: RichDocumentPayload?
            if recovery?.kind == .richDocument,
               let data = recovery?.richDocumentData {
                recoveredRich = await RichDocumentWorker.shared.load(data: data)
            } else {
                recoveredRich = nil
            }
            guard !Task.isCancelled, loadingURL == target else {
                abandonRecoveryClaim(snapshot.recoveryClaim, target: target)
                return
            }
            var restoredRecovery = false
            var recoveryMatchesDisk = false
            pdfDocument = nil
            switch snapshot.content {
            case let .text(text), let .markdown(text), let .html(text):
                content = snapshot.content
                savedText = text
                if recovery?.kind == .text,
                   let recovered = recovery?.text {
                    if recovered == text {
                        draft = text
                        recoveryMatchesDisk = true
                    } else {
                        draft = recovered
                        restoredRecovery = true
                    }
                } else {
                    draft = text
                }
            case .docx:
                savedRichText = rich?.value.copy() as? NSAttributedString ?? NSAttributedString(string: "")
                if let recoveredRich {
                    content = .docx
                    if let rich, recoveredRich.value.isEqual(to: rich.value) {
                        richDraft = rich.value
                        recoveryMatchesDisk = true
                    } else {
                        richDraft = recoveredRich.value
                        restoredRecovery = true
                    }
                } else if let rich {
                    content = .docx
                    richDraft = rich.value
                } else {
                    content = .unreadable
                    richDraft = NSAttributedString(string: "")
                }
            case .pdf:
                content = pdf == nil ? .unreadable : .pdf
                pdfDocument = pdf?.value
                savedText = ""
                savedRichText = NSAttributedString(string: "")
            default:
                savedText = ""
                savedRichText = NSAttributedString(string: "")
                if recovery?.kind == .text,
                   let recovered = recovery?.text {
                    let ext = target.pathExtension.lowercased()
                    if ext == "md" || ext == "markdown" { content = .markdown(recovered) }
                    else if ext == "html" || ext == "htm" { content = .html(recovered) }
                    else { content = .text(recovered) }
                    draft = recovered
                    restoredRecovery = true
                } else if let recoveredRich {
                    content = .docx
                    richDraft = recoveredRich.value
                    restoredRecovery = true
                } else {
                    content = snapshot.content
                    draft = ""
                }
            }
            if let recovery {
                ownedRecoveryToken = recovery.token
                claimedRecoverySourceTokens = snapshot.recoveryClaim?.sourceTokens ?? []
                recoveryRevision = max(recoveryRevision, recovery.revision)
                recoveryFencedRevision = 0
                if recoveryMatchesDisk || !restoredRecovery {
                    clearRecoveryTokens(for: target)
                }
            }
            // A path:line target opens editable source at the exact location;
            // ordinary file browsing keeps the calmer read-first presentation.
            switch snapshot.content {
            case .text, .html:
                isEditingText = targetLine != nil
            default:
                isEditingText = false
            }
            showMarkdownSource = false
            documentZoom = 1
            loadedURL = target
            loadingURL = nil
            recoveredDraftPending = restoredRecovery
            // A refused claim leaves the stored draft on disk. Carrying the
            // typed failure onto the banner is the only thing that keeps it
            // reachable from here.
            recoveryClaimFailure = snapshot.recoveryFailure.flatMap {
                FilePreviewRecoveryFailurePolicy.shouldSurface($0) ? $0 : nil
            }
            if ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
               ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "preview-dirty-tab",
               !restoredRecovery {
                draft += "\n\nUnsaved preview edit"
            }
            lastRecoverableRichDraft = richDraft.copy() as? NSAttributedString ?? richDraft
            loadedModificationDate = restoredRecovery
                ? recovery?.expectedModificationDate
                : snapshot.modificationDate
            if restoredRecovery {
                let diskChanged = snapshot.modificationDate != recovery?.expectedModificationDate
                previewNotice = .recoveredDraft(diskChanged: diskChanged)
            } else {
                previewNotice = nil
            }
            previewRevision &+= 1
            isLoading = false
            refreshHighlight()
            scheduleOutlineRefresh()
            navigationCommitted(target)
        }
    }

    private func promoteEditedPreviewIfNeeded() {
        guard FilePreviewTabPolicy.shouldPromoteEditedPreview(
            loadedURL: loadedURL,
            isDirty: isDirty,
            tabs: tabs
        ), let loadedURL else { return }
        let normalized = loadedURL.standardizedFileURL
        guard pendingEditedPreviewPromotion != normalized else { return }
        pendingEditedPreviewPromotion = normalized
        // `draft` changes arrive during SwiftUI's update transaction. Defer the
        // AppModel publication one turn to avoid publish-during-view-update
        // warnings under fast typing and Markdown autosave.
        Task { @MainActor in
            await Task.yield()
            setTabPinned(normalized, true)
            if pendingEditedPreviewPromotion == normalized {
                pendingEditedPreviewPromotion = nil
            }
        }
    }

    /// Rebuild the read-mode rendering of `draft` for the current file and
    /// appearance. Non-highlightable extensions (and non-text content) fall back
    /// to plain, label-colored text. The result carries no font, so a zoom step
    /// never triggers a re-highlight.
    private func refreshHighlight() {
        highlightTask?.cancel()
        guard case .text = content else {
            // Non-text content never reads `highlightedSource`, but leaving
            // it populated would keep the previous file's — potentially
            // very large — attributed string retained in this view's state
            // for the rest of its lifetime.
            highlightedSource = AttributedSource(value: NSAttributedString())
            return
        }
        let grammar = SyntaxHighlighter.grammar(
            forExtension: (loadedURL ?? url).pathExtension
        )
        let dark = colorScheme == .dark
        let source = draft
        // Publish the correct *text* immediately; color follows from the
        // background pass. Without this, returning from an edit would briefly
        // render the pre-edit snapshot.
        if highlightedSource.value.string != source {
            highlightedSource = SyntaxHighlighter.attributedSource(source, grammar: nil, dark: dark)
        }
        guard grammar != nil else { return }
        highlightTask = Task {
            let rendered = await Task.detached(priority: .utility) {
                SyntaxHighlighter.attributedSource(source, grammar: grammar, dark: dark)
            }.value
            guard !Task.isCancelled, source == draft else { return }
            highlightedSource = rendered
        }
    }

    /// Rebuild the native outline after a short typing debounce. Parsing stays
    /// off the MainActor and is bounded by both line and item count.
    private func scheduleOutlineRefresh() {
        outlineTask?.cancel()
        switch content {
        case .text, .markdown, .html:
            break
        default:
            outlineItems = []
            return
        }
        let source = draft
        let fileURL = (loadedURL ?? url).standardizedFileURL
        outlineTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let items = await Task.detached(priority: .utility) {
                SourceOutline.items(in: source, fileURL: fileURL)
            }.value
            guard !Task.isCancelled,
                  source == draft,
                  fileURL == (loadedURL ?? url).standardizedFileURL else { return }
            outlineItems = items
        }
    }

    /// Save exactly the snapshot currently displayed. `loadedURL` never moves
    /// until a load finishes, eliminating the old wrong-file race during fast
    /// tree navigation. The mtime check makes concurrent agent edits explicit.
    private func save(
        force: Bool = false,
        advancePendingAction: Bool = false,
        silently: Bool = false
    ) {
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
        recoveryJournalTask?.cancel()
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        recoveryRevision &+= 1
        let revision = recoveryRevision
        let store = recoveryStore
        let root = workspaceRoot
        let ownerID = recoveryOwnerID
        let sourceTokens = claimedRecoverySourceTokens
        let writeRegistration: FilePreviewRecoveryWriteRegistration
        do {
            writeRegistration = try store.beginInFlightWrite(
                ownerID: ownerID,
                revision: revision,
                for: target,
                workspaceRoot: root
            )
        } catch {
            handleRecoveryFailure(error, richDocument: savingRichDocument)
            resumePendingActionPrompt()
            return
        }
        isSaving = true
        saveTask?.cancel()
        saveTask = Task {
            let recoveryResult = await Task.detached(priority: .userInitiated) {
                defer { store.completeInFlightWrite(writeRegistration) }
                return FilePreviewRecoveryWork.persist(
                    store: store,
                    target: target,
                    workspaceRoot: root,
                    expectedModificationDate: expectedDate,
                    ownerID: ownerID,
                    revision: revision,
                    sourceTokens: sourceTokens,
                    text: textSnapshot,
                    richPayload: savingRichDocument ? richSnapshot : nil
                )
            }.value
            let shouldRetryPendingAutosave = FilePreviewNavigationPolicy.shouldRetrySupersededSave(
                taskCancelled: Task.isCancelled,
                remainsOnLoadedFile: loadedURL == target,
                recoveryGenerationChanged: recoveryGeneration != generation,
                autosavePendingAction: autosavePendingAction,
                hasPendingAction: pendingAction != nil
            )
            guard !Task.isCancelled,
                  loadedURL == target,
                  recoveryGeneration == generation else {
                if case let .saved(token) = recoveryResult {
                    Task.detached(priority: .utility) {
                        store.remove(token, for: target, workspaceRoot: root)
                    }
                }
                if loadedURL == target {
                    isSaving = false
                    saveTask = nil
                }
                if shouldRetryPendingAutosave {
                    save(advancePendingAction: true, silently: true)
                }
                return
            }
            switch recoveryResult {
            case let .saved(token):
                didPersistRecovery(token, richText: richSnapshot.value, richDocument: savingRichDocument)
            case let .failed(message, payloadTooLarge):
                isSaving = false
                saveTask = nil
                handleRecoveryFailure(
                    message: message,
                    payloadTooLarge: payloadTooLarge,
                    richDocument: savingRichDocument
                )
                resumePendingActionPrompt()
                return
            }

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
                recoveredDraftPending = false
                // The write either found the file untouched or came back
                // through the reload/overwrite decision, so the draft and the
                // file agree again.
                conflict.apply(.savedThroughConflictDecision)
                if savingRichDocument { savedRichText = richSnapshot.value }
                else { savedText = textSnapshot }
                guard clearRecoveryTokens(for: target) else {
                    resumePendingActionPrompt()
                    return
                }
                if case .html = content { previewRevision &+= 1 }
                previewNotice = nil
                if !silently {
                    ToastCenter.shared.show("Saved \(target.lastPathComponent)", style: .success)
                }
                let completion = FilePreviewNavigationPolicy.saveCompletion(
                    hasPendingAction: pendingAction != nil
                        && (advancePendingAction || autosavePendingAction),
                    isDirty: isDirty,
                    isMarkdown: isMarkdownContent
                )
                switch completion {
                case .stay:
                    break
                case .completePendingAction:
                    completePendingAction()
                case .saveLatestDraft:
                    autosavePendingAction = true
                    save(advancePendingAction: true, silently: true)
                case .prompt:
                    resumePendingActionPrompt()
                }
                if completion == .stay, isMarkdownContent, isDirty {
                    scheduleMarkdownAutosave()
                }
            case .changedOnDisk:
                autosavePendingAction = false
                showExternalChangePrompt = true
            case let .failed(message):
                previewNotice = .error(message)
                ToastCenter.shared.show(message, style: .error)
                resumePendingActionPrompt()
            }
        }
    }

    /// A failed automatic or user-requested save must not strand AppModel on a
    /// new selection while the old dirty document remains mounted. Return to
    /// the explicit Save / Discard / Cancel decision on the next main turn.
    private func resumePendingActionPrompt() {
        guard pendingAction != nil else { return }
        autosavePendingAction = false
        Task { @MainActor in
            await Task.yield()
            if pendingAction != nil { showUnsavedPrompt = true }
        }
    }

    /// Rendered Markdown is a direct editor rather than a preview/source
    /// toggle. Save after a short quiet period so the document behaves like a
    /// modern notes surface while retaining the existing mtime conflict guard.
    private func scheduleMarkdownAutosave() {
        markdownAutosaveTask?.cancel()
        // The disposable dirty-tab fixture must survive long enough to prove
        // the modified marker. Its document lives in the fixture-only 0700
        // store, and every production surface keeps normal autosave behavior.
        if ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
           ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "preview-dirty-tab" {
            return
        }
        guard case .markdown = content,
              loadedURL != nil,
              !isLoading,
              draft != savedText,
              !showExternalChangePrompt else { return }
        markdownAutosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            if isSaving {
                scheduleMarkdownAutosave()
            } else {
                save(silently: true)
            }
        }
    }

    /// A short recovery-only debounce protects ordinary text, Markdown, HTML,
    /// and DOCX editing from hard crashes without touching the project file or
    /// turning each keystroke into a filesystem sync.
    private func scheduleRecoveryJournal() {
        recoveryJournalTask?.cancel()
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        guard let target = loadedURL,
              !isLoading,
              isEditable,
              isDirty else { return }
        recoveryJournalTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled,
                  loadedURL == target,
                  recoveryGeneration == generation,
                  isDirty else { return }
            let savingRichDocument: Bool = {
                if case .docx = content { return true }
                return false
            }()
            let textSnapshot = draft
            let richSnapshot = RichDocumentPayload(
                value: richDraft.copy() as? NSAttributedString ?? richDraft
            )
            recoveryRevision &+= 1
            let revision = recoveryRevision
            let store = recoveryStore
            let root = workspaceRoot
            let ownerID = recoveryOwnerID
            let expectedDate = loadedModificationDate
            let sourceTokens = claimedRecoverySourceTokens
            let writeRegistration: FilePreviewRecoveryWriteRegistration
            do {
                writeRegistration = try store.beginInFlightWrite(
                    ownerID: ownerID,
                    revision: revision,
                    for: target,
                    workspaceRoot: root
                )
            } catch {
                handleRecoveryFailure(error, richDocument: savingRichDocument)
                recoveryJournalTask = nil
                return
            }
            let result = await Task.detached(priority: .utility) {
                defer { store.completeInFlightWrite(writeRegistration) }
                return FilePreviewRecoveryWork.persist(
                    store: store,
                    target: target,
                    workspaceRoot: root,
                    expectedModificationDate: expectedDate,
                    ownerID: ownerID,
                    revision: revision,
                    sourceTokens: sourceTokens,
                    text: textSnapshot,
                    richPayload: savingRichDocument ? richSnapshot : nil
                )
            }.value
            guard !Task.isCancelled,
                  loadedURL == target,
                  recoveryGeneration == generation else {
                if case let .saved(token) = result {
                    Task.detached(priority: .utility) {
                        store.remove(token, for: target, workspaceRoot: root)
                    }
                }
                return
            }
            switch result {
            case let .saved(token):
                didPersistRecovery(
                    token,
                    richText: richSnapshot.value,
                    richDocument: savingRichDocument
                )
            case let .failed(message, payloadTooLarge):
                handleRecoveryFailure(
                    message: message,
                    payloadTooLarge: payloadTooLarge,
                    richDocument: savingRichDocument
                )
            }
            recoveryJournalTask = nil
        }
    }

    /// Used only by the app-termination/view-dismissal barrier. Normal editing
    /// and explicit saves use `FilePreviewRecoveryWork` on a utility executor.
    private func persistRecoverySynchronously(
        target: URL,
        text: String,
        richText: NSAttributedString,
        richDocument: Bool
    ) throws -> FilePreviewRecoveryToken {
        recoveryRevision &+= 1
        if richDocument {
            let data = try RichDocumentIO.data(richText)
            guard FilePreviewDraftBounds.acceptsSerializedRichDocumentData(data) else {
                throw FilePreviewRecoveryStore.RecoveryError.payloadTooLarge
            }
            return try recoveryStore.saveRichDocument(
                data,
                for: target,
                workspaceRoot: workspaceRoot,
                expectedModificationDate: loadedModificationDate,
                ownerID: recoveryOwnerID,
                revision: recoveryRevision,
                sourceTokens: claimedRecoverySourceTokens
            )
        } else {
            return try recoveryStore.saveText(
                text,
                for: target,
                workspaceRoot: workspaceRoot,
                expectedModificationDate: loadedModificationDate,
                ownerID: recoveryOwnerID,
                revision: recoveryRevision,
                sourceTokens: claimedRecoverySourceTokens
            )
        }
    }

    private func didPersistRecovery(
        _ token: FilePreviewRecoveryToken,
        richText: NSAttributedString,
        richDocument: Bool
    ) {
        ownedRecoveryToken = token
        recoveryFencedRevision = 0
        recoveryFencedSourceTokens = []
        recoveryFenceToken = nil
        if richDocument {
            lastRecoverableRichDraft = richText.copy() as? NSAttributedString ?? richText
        }
    }

    @discardableResult
    private func clearRecoveryTokens(for target: URL) -> Bool {
        recoveryJournalTask?.cancel()
        recoveryGeneration &+= 1
        let sourceTokens = claimedRecoverySourceTokens
        let uncoveredSources = Set(sourceTokens).subtracting(recoveryFencedSourceTokens)
        if recoveryRevision > recoveryFencedRevision || !uncoveredSources.isEmpty {
            do {
                let fenceToken = try recoveryStore.fence(
                    ownerID: recoveryOwnerID,
                    through: recoveryRevision,
                    for: target,
                    workspaceRoot: workspaceRoot,
                    resolving: sourceTokens
                )
                recoveryRevision = fenceToken.revision
                recoveryFencedRevision = fenceToken.revision
                recoveryFencedSourceTokens = sourceTokens
                recoveryFenceToken = fenceToken
            } catch {
                handleRecoveryFailure(error, richDocument: false)
                return false
            }
        }
        // Physical deletion is now an optimization. The durable tombstone
        // already suppresses these exact sources if the process dies here.
        let store = recoveryStore
        let root = workspaceRoot
        let ownerID = recoveryOwnerID
        let fenceToken = recoveryFenceToken
        Task.detached(priority: .utility) {
            if let fenceToken {
                store.retireFenceWhenSafe(
                    fenceToken,
                    through: fenceToken.revision - 1,
                    for: target,
                    workspaceRoot: root
                )
            }
            store.releaseClaims(
                sourceTokens,
                for: target,
                workspaceRoot: root,
                claimantID: ownerID
            )
        }
        ownedRecoveryToken = nil
        return true
    }

    /// A cancelled load must remove only the claimant copy. Its orphan source
    /// is left intact and made available to the next view.
    private func abandonRecoveryClaim(_ claim: FilePreviewRecoveryClaim?, target: URL) {
        guard let claim else { return }
        recoveryStore.remove(claim.record.token, for: target, workspaceRoot: workspaceRoot)
        recoveryStore.releaseClaims(
            claim.sourceTokens,
            for: target,
            workspaceRoot: workspaceRoot,
            claimantID: recoveryOwnerID
        )
    }

    private func releaseRecoveryClaims() {
        guard let target = loadedURL, !claimedRecoverySourceTokens.isEmpty else { return }
        recoveryStore.releaseClaims(
            claimedRecoverySourceTokens,
            for: target,
            workspaceRoot: workspaceRoot,
            claimantID: recoveryOwnerID
        )
    }

    private func handleRecoveryFailure(_ error: Error, richDocument: Bool) {
        handleRecoveryFailure(
            message: error.localizedDescription,
            payloadTooLarge: (error as? FilePreviewRecoveryStore.RecoveryError) == .payloadTooLarge,
            richDocument: richDocument
        )
    }

    private func handleRecoveryFailure(
        message: String,
        payloadTooLarge: Bool,
        richDocument: Bool
    ) {
        previewNotice = .error(message)
        if richDocument, payloadTooLarge {
            richDraft = lastRecoverableRichDraft
            recoveredDraftPending = !richDraft.isEqual(to: savedRichText)
        }
        ToastCenter.shared.show(message, style: .error)
    }

    private func reportOversizedDraft() {
        let message = "This edit is too large for safe preview recovery."
        previewNotice = .error(message)
        ToastCenter.shared.show(message, style: .error)
    }

    /// A preview dismissal or app quit must never discard the only copy of a
    /// draft. Text previews are capped at 1 MB and rich documents at 20 MB, so
    /// this rare lifecycle barrier performs one bounded atomic write before the
    /// view leaves the hierarchy. A save already in flight owns the same latest
    /// immutable snapshot (editing is disabled while saving) and is allowed to
    /// finish instead of being cancelled by teardown.
    private func flushPendingPreviewSave() {
        markdownAutosaveTask?.cancel()
        recoveryJournalTask?.cancel()
        recoveryGeneration &+= 1
        guard let target = loadedURL else { return }
        guard isDirty else {
            clearRecoveryTokens(for: target)
            return
        }

        let textSnapshot = draft
        let richSnapshot = richDraft.copy() as? NSAttributedString ?? richDraft
        let savingRichDocument: Bool = {
            if case .docx = content { return true }
            return false
        }()
        let recoveryToken: FilePreviewRecoveryToken
        do {
            recoveryToken = try persistRecoverySynchronously(
                target: target,
                text: textSnapshot,
                richText: richSnapshot,
                richDocument: savingRichDocument
            )
            didPersistRecovery(recoveryToken, richText: richSnapshot, richDocument: savingRichDocument)
        } catch {
            handleRecoveryFailure(error, richDocument: savingRichDocument)
            return
        }
        // The durable snapshot above is the lifecycle guarantee. Avoid racing
        // an in-flight writer or bypassing an unresolved external-edit choice.
        guard !isSaving, !showExternalChangePrompt else { return }

        let result: FilePreviewSaveResult
        if savingRichDocument {
            guard !FilePreviewDiskState.changed(onDisk: target, since: loadedModificationDate) else {
                previewNotice = .warning("The file changed on disk. Your open draft was not overwritten.")
                return
            }
            do {
                try RichDocumentIO.write(richSnapshot, to: target)
                result = .saved(FilePreviewDiskState.modificationDate(of: target))
            } catch {
                result = .failed(error.localizedDescription)
            }
        } else {
            result = FilePreviewDiskState.writeText(
                textSnapshot,
                to: target,
                expectedModificationDate: loadedModificationDate,
                force: false
            )
        }

        switch result {
        case let .saved(modificationDate):
            recoveredDraftPending = false
            conflict.apply(.savedThroughConflictDecision)
            if savingRichDocument { savedRichText = richSnapshot }
            else { savedText = textSnapshot }
            loadedModificationDate = modificationDate
            guard clearRecoveryTokens(for: target) else { return }
            previewNotice = nil
        case .changedOnDisk:
            previewNotice = .warning("The file changed on disk. Your open draft was not overwritten.")
        case let .failed(message):
            previewNotice = .error(message)
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
