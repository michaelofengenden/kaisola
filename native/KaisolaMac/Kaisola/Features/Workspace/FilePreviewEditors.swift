import AppKit
import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// NSAttributedString's DOCX importer/exporter is synchronous. A dedicated
/// actor serializes rich-document work off the MainActor, so rapid file switches
/// cannot pile up AppKit parses or freeze terminal rendering.
actor RichDocumentWorker {
    static let shared = RichDocumentWorker()

    func load(url: URL) -> RichDocumentPayload? {
        RichDocumentIO.load(url: url)
    }

    func load(data: Data) -> RichDocumentPayload? {
        RichDocumentIO.load(data: data)
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

/// PDF parsing is synchronous. Serialize it away from the MainActor so opening
/// a bounded but image-heavy document cannot stall terminals or pointer input.
actor PDFDocumentWorker {
    static let shared = PDFDocumentWorker()

    func load(url: URL) -> PDFDocumentPayload? {
        PDFDocumentIO.load(url: url)
    }
}

struct RichDocumentCommand: Equatable {
    enum Kind: Equatable { case bold, italic, underline, heading, bulletList }
    let id = UUID()
    let kind: Kind
}
/// Native, selectable PDF rendering with PDFKit's own scrolling, page layout,
/// accessibility, and trackpad magnification behavior. The parsed
/// document arrives from `PDFDocumentWorker`; this representable only mounts it.
struct PDFFilePreview: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = .underPageBackgroundColor
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard view.document !== document else { return }
        view.document = document
        view.autoScales = true
    }

    static func dismantleNSView(_ view: PDFView, coordinator: ()) {
        view.document = nil
    }
}

/// Lightweight syntax roles for the rendered Markdown editor. The spans are
/// computed off the main actor and applied as TextKit temporary attributes, so
/// the file remains exact Markdown source even though it reads like a document.
struct MarkdownEditingStyle: Sendable {
    enum Role: Hashable, Sendable {
        case heading(Int)
        case quote
        case codeBlock
        case bold
        case italic
        case inlineCode
        case link
        case listMarker
        case centered
        case syntax
    }

    struct Span: Hashable, Sendable {
        let range: NSRange
        let role: Role
    }

    nonisolated static func spans(in source: String) -> [Span] {
        guard !source.isEmpty else { return [] }
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        var result: [Span] = []

        func collect(
            _ pattern: String,
            options: NSRegularExpression.Options = [],
            role: (NSTextCheckingResult) -> Role?,
            contentGroup: Int = 0,
            syntaxGroups: [Int] = []
        ) {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            expression.enumerateMatches(in: source, range: fullRange) { match, _, _ in
                guard let match,
                      let resolvedRole = role(match),
                      contentGroup < match.numberOfRanges else { return }
                let range = match.range(at: contentGroup)
                if range.location != NSNotFound, range.length > 0 {
                    result.append(Span(range: range, role: resolvedRole))
                }
                for group in syntaxGroups where group < match.numberOfRanges {
                    let syntaxRange = match.range(at: group)
                    if syntaxRange.location != NSNotFound, syntaxRange.length > 0 {
                        result.append(Span(range: syntaxRange, role: .syntax))
                    }
                }
            }
        }

        // Inline roles are applied first. Block roles that overlap them are
        // appended later and therefore remain visually dominant.
        collect(#"(?<!\*)(\*\*)([^*\n]+)(\*\*)(?!\*)"#, role: { _ in .bold }, contentGroup: 2, syntaxGroups: [1, 3])
        collect(#"(?<!_)(__)([^_\n]+)(__)(?!_)"#, role: { _ in .bold }, contentGroup: 2, syntaxGroups: [1, 3])
        collect(#"(?<!\*)(\*)([^*\n]+)(\*)(?!\*)"#, role: { _ in .italic }, contentGroup: 2, syntaxGroups: [1, 3])
        collect(#"(?<!_)(_)([^_\n]+)(_)(?!_)"#, role: { _ in .italic }, contentGroup: 2, syntaxGroups: [1, 3])
        collect(#"(`)([^`\n]+)(`)"#, role: { _ in .inlineCode }, contentGroup: 2, syntaxGroups: [1, 3])
        collect(
            #"(!?\[)([^]\r\n]+)(\]\()([^)\r\n]+)(\))"#,
            role: { _ in .link },
            contentGroup: 2,
            syntaxGroups: [1, 3, 4, 5]
        )
        // README files commonly mix a small, presentational HTML subset into
        // Markdown. Keep the exact source editable, but style the human text
        // and collapse the tags just like Markdown delimiters. The raw-source
        // toggle remains available for changing attributes/URLs explicitly.
        collect(#"(?is)(<h([1-6])\b[^>]*>)(.*?)(</h\2\s*>)"#, role: { match in
            let levelRange = match.range(at: 2)
            guard levelRange.location != NSNotFound else { return nil }
            return .heading(Int((source as NSString).substring(with: levelRange)) ?? 1)
        }, contentGroup: 3, syntaxGroups: [1, 4])
        collect(#"(?is)(<strong\b[^>]*>)(.*?)(</strong\s*>)"#, role: { _ in .bold }, contentGroup: 2, syntaxGroups: [1, 3])
        collect(#"(?is)(<(?:em|i)\b[^>]*>)(.*?)(</(?:em|i)\s*>)"#, role: { _ in .italic }, contentGroup: 2, syntaxGroups: [1, 3])
        collect(#"(?is)(<code\b[^>]*>)(.*?)(</code\s*>)"#, role: { _ in .inlineCode }, contentGroup: 2, syntaxGroups: [1, 3])
        collect(#"(?is)(<a\b[^>]*>)(.*?)(</a\s*>)"#, role: { _ in .link }, contentGroup: 2, syntaxGroups: [1, 3])
        collect(
            #"(?is)(<(?:h[1-6]|p)\b[^>]*\balign\s*=\s*[\"']?center[\"']?[^>]*>)(.*?)(</(?:h[1-6]|p)\s*>)"#,
            role: { _ in .centered },
            contentGroup: 2
        )
        // Hide only plausible single-line HTML tags. The former dot-all
        // `<[^>]+>` rule could span paragraphs and make ordinary comparisons
        // such as `a < b and c > d` disappear from the rendered editor.
        collect(#"(?i)</?[A-Za-z][^>\n]*>"#, role: { _ in .syntax })
        collect(#"(?m)^(#{1,6})(?:[ \t]+)(.+)$"#, role: { match in
            .heading(min(6, match.range(at: 1).length))
        }, contentGroup: 2, syntaxGroups: [1])
        collect(#"(?m)^([ \t]*>[ \t]?)(.*)$"#, role: { _ in .quote }, contentGroup: 2, syntaxGroups: [1])
        // Keep list markers visible while editing. Unlike emphasis and link
        // delimiters, the marker is meaningful document chrome: showing it
        // makes Return-driven list continuation feel immediate and keeps the
        // current nesting level obvious without exposing the rest of the raw
        // Markdown syntax.
        collect(#"(?m)^([ \t]*(?:[-+*]|[0-9]+\.)[ \t]+)"#, role: { _ in .listMarker })
        collect(
            #"(?ms)^([ \t]*(?:```|~~~)[^\n]*\n).*?^([ \t]*(?:```|~~~)[ \t]*$)"#,
            role: { _ in .codeBlock }
        )
        // Several semantic recognizers intentionally overlap (for example an
        // `<em>` pair is found both by the emphasis rule and by the generic
        // tag rule). Apply each identical style/range once so TextKit does not
        // redo temporary-attribute work while scrolling a Markdown document.
        var seen: Set<Span> = []
        var unique: [Span] = []
        unique.reserveCapacity(min(result.count, 20_000))
        for span in result where seen.insert(span).inserted {
            unique.append(span)
            if unique.count == 20_000 { break }
        }
        return unique
    }
}

/// Plain source editor used when a terminal/chat opens `path:line`. TextKit
/// gives us exact one-based line navigation while retaining native selection,
/// undo, find, and a lightweight editing surface.
enum FileLineNavigation {
    static func range(forOneBasedLine line: Int, in text: String) -> NSRange {
        let source = text as NSString
        guard source.length > 0 else { return NSRange(location: 0, length: 0) }
        var location = 0
        var current = 1
        while current < line, location < source.length {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            current += 1
        }
        guard current == line else { return NSRange(location: source.length, length: 0) }
        return source.lineRange(for: NSRange(location: location, length: 0))
    }
}

/// Remembers where each document was last scrolled to, as the fraction of its
/// scrollable range sitting at the top of the viewport.
///
/// Read mode and the editor are two text views laying the same file out with
/// different machinery, so a raw pixel offset does not survive the toggle.
/// A character offset sounds more meaningful, but TextKit 2 answers geometry
/// questions about text it has not laid out with end-of-document values, so an
/// offset cannot be turned back into a scroll position without first laying out
/// the whole file — exactly the cost the viewport exists to avoid. Both surfaces
/// render the same monospaced source without wrapping, so every line is the same
/// height and the fraction transfers directly.
///
/// Without this, every switch between reading and editing threw the view back to
/// line 1, which is what made the toggle feel destructive on a long file.
///
/// Bounded so a long session cannot accumulate one entry per file ever opened.
final class FilePreviewTextScrollMemory {
    static let capacity = 32

    private var fractions: [String: Double] = [:]
    /// Least-recently recorded first.
    private var recency: [String] = []

    var trackedDocumentCount: Int { fractions.count }

    func record(_ fraction: Double, for documentID: String) {
        guard !documentID.isEmpty, fraction.isFinite else { return }
        fractions[documentID] = min(1, max(0, fraction))
        recency.removeAll { $0 == documentID }
        recency.append(documentID)
        while recency.count > Self.capacity {
            fractions[recency.removeFirst()] = nil
        }
    }

    /// The remembered fraction, or `nil` when the document was never scrolled —
    /// the surface then opens at its natural top instead of pretending to
    /// restore something.
    func fraction(for documentID: String) -> Double? {
        fractions[documentID]
    }

    func forget(_ documentID: String) {
        fractions[documentID] = nil
        recency.removeAll { $0 == documentID }
    }
}

/// Viewport measurement and restoration shared by the preview's two text
/// surfaces so they agree on what "the same place" means.
@MainActor
enum FilePreviewTextScroll {
    /// Whether the pair is currently laid out well enough to trust a
    /// measurement. A view being torn down still answers geometry questions,
    /// just not usefully, and recording a garbage position would poison the
    /// next restore.
    static func canMeasure(_ textView: NSTextView, in scrollView: NSScrollView) -> Bool {
        textView.window != nil
            && scrollView.contentView.bounds.height > 0
            && !textView.string.isEmpty
    }

    /// How far down its scrollable range the view currently sits, 0...1.
    static func scrollFraction(in textView: NSTextView, scrollView: NSScrollView) -> Double {
        let scrollable = scrollableHeight(textView, scrollView)
        guard scrollable > 0 else { return 0 }
        return min(1, max(0, Double(scrollView.contentView.bounds.origin.y / scrollable)))
    }

    /// Put `fraction` of the scrollable range above the viewport.
    static func scroll(to fraction: Double, in textView: NSTextView, scrollView: NSScrollView) {
        let clip = scrollView.contentView
        let scrollable = scrollableHeight(textView, scrollView)
        clip.scroll(to: NSPoint(x: 0, y: CGFloat(min(1, max(0, fraction))) * scrollable))
        scrollView.reflectScrolledClipView(clip)
    }

    private static func scrollableHeight(_ textView: NSTextView, _ scrollView: NSScrollView) -> CGFloat {
        max(0, textView.bounds.height - scrollView.contentView.bounds.height)
    }
}

/// Read-only source text on TextKit 2.
///
/// Read mode used to render the whole file as a single SwiftUI `Text`, which
/// laid out and drew every line up front and beach-balled as files approached
/// the 1 MiB preview ceiling. `NSTextLayoutManager` lays out only the visible
/// viewport, so opening a large file costs what is on screen rather than what is
/// in the file. The surface keeps native selection and copy, turns on the
/// standard find bar so Command-F works while reading, and shares its
/// top-of-viewport offset with the editor so the mode toggle stays put.
struct SourceTextReader: NSViewRepresentable {
    let source: NSAttributedString
    let fontSize: CGFloat
    let documentID: String
    let scrollMemory: FilePreviewTextScrollMemory

    func makeCoordinator() -> Coordinator { Coordinator(scrollMemory: scrollMemory) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        // Constructing with `frame:` silently selects TextKit 1; this is the
        // explicit opt-in that makes layout viewport-sized.
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.backgroundColor = .textBackgroundColor
        textView.setAccessibilityLabel("File contents")

        scrollView.documentView = textView
        context.coordinator.attach(textView: textView, scrollView: scrollView)
        context.coordinator.apply(source: source, fontSize: fontSize, documentID: documentID)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(source: source, fontSize: fontSize, documentID: documentID)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.recordScrollPosition()
    }

    @MainActor
    final class Coordinator: NSObject {
        private let scrollMemory: FilePreviewTextScrollMemory
        private weak var textView: NSTextView?
        private weak var scrollView: NSScrollView?
        private var appliedSource: NSAttributedString?
        private var appliedFontSize: CGFloat?
        private var documentID = ""
        /// Suppresses recording until the restore for the current document has
        /// run; the layout passes before it would otherwise overwrite the
        /// remembered offset with zero.
        private var pendingRestore = true
        /// Non-zero while this coordinator is scrolling the view itself. The
        /// clip view posts its bounds notification synchronously, so without
        /// this every position a restore passes through is recorded as if the
        /// user had scrolled there — and the last one wins.
        private var programmaticScrollDepth = 0

        init(scrollMemory: FilePreviewTextScrollMemory) {
            self.scrollMemory = scrollMemory
        }

        func attach(textView: NSTextView, scrollView: NSScrollView) {
            self.textView = textView
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            // Selector-based registration is zeroing-weak, so no explicit
            // removal is needed when the coordinator goes away.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(viewportDidScroll),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        @objc private func viewportDidScroll() {
            recordScrollPosition()
        }

        func apply(source: NSAttributedString, fontSize: CGFloat, documentID: String) {
            guard let textView, let storage = textView.textStorage else { return }
            if self.documentID != documentID {
                recordScrollPosition()
                self.documentID = documentID
                pendingRestore = true
            }
            // Identity, not equality: the highlighter publishes a fresh
            // immutable string only when the source, language, or appearance
            // actually changed, so a hover-driven body evaluation costs one
            // pointer comparison instead of a full re-install.
            if appliedSource !== source {
                appliedSource = source
                // Arm the guard before the storage swap: replacing the text
                // storage moves the clip origin synchronously, which would
                // otherwise let `recordScrollPosition` observe the resulting
                // bounds-change notification and poison the remembered
                // fraction with the collapsed (≈0) position before restore
                // ever runs.
                pendingRestore = true
                storage.setAttributedString(source)
                // Storage replacement drops the font applied over the old text.
                appliedFontSize = nil
            }
            if appliedFontSize != fontSize {
                appliedFontSize = fontSize
                textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            }
            guard pendingRestore else { return }
            // The view has no useful geometry during `makeNSView`; restore once
            // AppKit has sized it.
            DispatchQueue.main.async { [weak self] in self?.restoreScrollPosition() }
        }

        func recordScrollPosition() {
            guard !pendingRestore, programmaticScrollDepth == 0,
                  let textView, let scrollView,
                  FilePreviewTextScroll.canMeasure(textView, in: scrollView) else { return }
            scrollMemory.record(
                FilePreviewTextScroll.scrollFraction(in: textView, scrollView: scrollView),
                for: documentID
            )
        }

        private func restoreScrollPosition() {
            guard pendingRestore, let textView, let scrollView else { return }
            pendingRestore = false
            guard let fraction = scrollMemory.fraction(for: documentID), fraction > 0 else { return }
            programmaticScrollDepth += 1
            FilePreviewTextScroll.scroll(to: fraction, in: textView, scrollView: scrollView)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // The first pass makes TextKit 2 lay out the region it landed
                // on, which sharpens its estimate of the whole document's
                // height; re-applying the same fraction against the corrected
                // height removes most of the residual drift. Releasing the
                // suppression only here also covers any bounds notification
                // AppKit defers past the synchronous scroll.
                if let textView = self.textView, let scrollView = self.scrollView,
                   FilePreviewTextScroll.canMeasure(textView, in: scrollView) {
                    FilePreviewTextScroll.scroll(
                        to: fraction,
                        in: textView,
                        scrollView: scrollView
                    )
                }
                self.programmaticScrollDepth -= 1
            }
        }
    }
}

struct LineTargetTextEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let targetLine: Int?
    var navigationRevision: UInt64 = 0
    let documentID: String
    var markdownURL: URL? = nil
    var workspaceRoot: URL? = nil
    var onError: ((String) -> Void)? = nil
    var autoFocus = false
    var magnification: CGFloat? = nil
    var onMagnificationChanged: ((CGFloat) -> Void)? = nil
    /// Shared with the read-only reader so toggling modes keeps the same line
    /// at the top. `nil` for surfaces that do not participate.
    var scrollMemory: FilePreviewTextScrollMemory? = nil

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView: NSScrollView
        if markdownURL != nil, let magnification {
            let markdownScrollView = MarkdownMagnifyingScrollView()
            markdownScrollView.allowsMagnification = true
            markdownScrollView.minMagnification = 0.65
            markdownScrollView.maxMagnification = 2
            markdownScrollView.magnification = magnification
            markdownScrollView.onMagnificationChanged = onMagnificationChanged
            scrollView = markdownScrollView
        } else {
            scrollView = NSScrollView()
        }
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = markdownURL == nil
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView: NSTextView
        if markdownURL != nil {
            // The whole-file Markdown source surface is the deliberately
            // narrow TextKit 2 pilot.  Constructing with `frame:` silently
            // selects TextKit 1; opting in here keeps exact source editing
            // while allowing viewport-based layout for large documents.  The
            // rendered editor stays on TextKit 1 for now because its
            // presentation-only syntax hiding uses temporary NSLayoutManager
            // attributes and must not mutate document bytes.
            let markdownTextView = MarkdownNativeTextView.wholeFileSourceEditor()
            markdownTextView.registerForDraggedTypes([.fileURL, .png, .tiff])
            markdownTextView.onImageImports = { [weak coordinator = context.coordinator] imports, range in
                coordinator?.importImages(imports, at: range)
            }
            markdownTextView.onChooseImages = { [weak coordinator = context.coordinator] range in
                coordinator?.chooseImages(at: range)
            }
            textView = markdownTextView
        } else {
            textView = NSTextView(frame: .zero)
        }
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = markdownURL == nil
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: markdownURL == nil ? CGFloat.greatestFiniteMagnitude : 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = markdownURL != nil
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.backgroundColor = .textBackgroundColor
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.string = text
        scrollView.documentView = textView
        (scrollView as? MarkdownMagnifyingScrollView)?.reflowDocumentWidth()
        context.coordinator.textView = textView
        context.coordinator.markdownURL = markdownURL
        context.coordinator.workspaceRoot = workspaceRoot
        context.coordinator.onError = onError
        context.coordinator.attachScrollRetention(
            memory: scrollMemory,
            scrollView: scrollView,
            documentID: documentID,
            // An explicit `path:line` target owns the initial position; the
            // remembered offset must not fight it.
            hasLineTarget: targetLine != nil
        )
        context.coordinator.scrollIfNeeded(
            to: targetLine,
            documentID: documentID,
            navigationRevision: navigationRevision
        )
        if autoFocus {
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.markdownURL = markdownURL
        context.coordinator.workspaceRoot = workspaceRoot
        context.coordinator.onError = onError
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            let selection = textView.selectedRange()
            context.coordinator.isApplyingExternalValue = true
            // Assigning `.string` resets the clip origin synchronously, the
            // same way the reader's `storage.setAttributedString` does.
            // Bracket it so the resulting bounds notification isn't
            // recorded as a real scroll, and schedule a restore afterward —
            // `attachScrollRetention`'s idempotent early return only re-arms
            // one on a document change, so a same-document external reload
            // would otherwise leave the view pinned at the collapsed
            // position with recording disabled for good.
            context.coordinator.beginExternalTextReplacement()
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selection.location, (text as NSString).length),
                length: 0
            ))
            context.coordinator.isApplyingExternalValue = false
            context.coordinator.endExternalTextReplacement(scheduleRestore: targetLine == nil)
        }
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if let markdownScrollView = scrollView as? MarkdownMagnifyingScrollView {
            markdownScrollView.onMagnificationChanged = onMagnificationChanged
            if let magnification, abs(markdownScrollView.magnification - magnification) > 0.001 {
                let center = NSPoint(
                    x: markdownScrollView.contentView.bounds.midX,
                    y: markdownScrollView.contentView.bounds.midY
                )
                markdownScrollView.setMagnification(magnification, centeredAt: center)
            }
            markdownScrollView.reflowDocumentWidth()
        }
        context.coordinator.attachScrollRetention(
            memory: scrollMemory,
            scrollView: scrollView,
            documentID: documentID,
            hasLineTarget: targetLine != nil
        )
        context.coordinator.scrollIfNeeded(
            to: targetLine,
            documentID: documentID,
            navigationRevision: navigationRevision
        )
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.recordScrollPosition()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?
        var markdownURL: URL?
        var workspaceRoot: URL?
        var onError: ((String) -> Void)?
        var isApplyingExternalValue = false
        private var lastScrollKey: String?
        private var importTask: Task<Void, Never>?
        private var scrollMemory: FilePreviewTextScrollMemory?
        private weak var scrollView: NSScrollView?
        private var scrollDocumentID = ""
        private var pendingRestore = false
        /// See the reader's coordinator: the clip view's bounds notification is
        /// synchronous, so a restore would otherwise record every position it
        /// scrolls through.
        private var programmaticScrollDepth = 0

        init(text: Binding<String>) { _text = text }

        deinit { importTask?.cancel() }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalValue,
                  let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        /// Join the shared top-of-viewport retention. Idempotent: `updateNSView`
        /// calls this on every body evaluation, and only a document change (or
        /// the first attach) re-arms a restore.
        func attachScrollRetention(
            memory: FilePreviewTextScrollMemory?,
            scrollView: NSScrollView,
            documentID: String,
            hasLineTarget: Bool
        ) {
            guard let memory else { return }
            let isFirstAttach = scrollMemory == nil
            if !isFirstAttach, scrollDocumentID == documentID { return }
            if !isFirstAttach { recordScrollPosition() }
            scrollMemory = memory
            self.scrollView = scrollView
            scrollDocumentID = documentID
            pendingRestore = true
            if isFirstAttach {
                scrollView.contentView.postsBoundsChangedNotifications = true
                // Selector-based registration is zeroing-weak, so no explicit
                // removal is needed when the coordinator goes away.
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(viewportDidScroll),
                    name: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView
                )
            }
            guard !hasLineTarget else {
                // The line target places the caret itself; just stop suppressing
                // recording so the user's own scrolling is remembered.
                DispatchQueue.main.async { [weak self] in self?.pendingRestore = false }
                return
            }
            DispatchQueue.main.async { [weak self] in self?.restoreScrollPosition() }
        }

        /// Arm the same guard `attachScrollRetention` uses, ahead of an
        /// external `textView.string` replacement: the assignment collapses
        /// the clip origin synchronously, and without suppressing here
        /// `recordScrollPosition` would capture that collapse as a real
        /// position for whichever document `scrollDocumentID` currently
        /// names.
        func beginExternalTextReplacement() {
            pendingRestore = true
            programmaticScrollDepth += 1
        }

        /// Release the synchronous suppression armed above. `scheduleRestore`
        /// should be `false` when an explicit line target will place the
        /// caret itself (mirroring `attachScrollRetention`'s own
        /// `hasLineTarget` branch); otherwise perform the restore that
        /// `attachScrollRetention`'s idempotent early return skips whenever
        /// the document identity did not change, so a same-document external
        /// reload still gets its scroll position put back.
        func endExternalTextReplacement(scheduleRestore: Bool) {
            programmaticScrollDepth -= 1
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if scheduleRestore {
                    self.restoreScrollPosition()
                } else {
                    self.pendingRestore = false
                }
            }
        }

        @objc private func viewportDidScroll() {
            recordScrollPosition()
        }

        func recordScrollPosition() {
            guard !pendingRestore, programmaticScrollDepth == 0,
                  let scrollMemory, let textView, let scrollView,
                  FilePreviewTextScroll.canMeasure(textView, in: scrollView) else { return }
            scrollMemory.record(
                FilePreviewTextScroll.scrollFraction(in: textView, scrollView: scrollView),
                for: scrollDocumentID
            )
        }

        private func restoreScrollPosition() {
            guard pendingRestore, let scrollMemory, let textView, let scrollView else { return }
            pendingRestore = false
            guard let fraction = scrollMemory.fraction(for: scrollDocumentID), fraction > 0 else { return }
            programmaticScrollDepth += 1
            FilePreviewTextScroll.scroll(to: fraction, in: textView, scrollView: scrollView)
            DispatchQueue.main.async { [weak self] in
                self?.programmaticScrollDepth -= 1
            }
        }

        func scrollIfNeeded(
            to oneBasedLine: Int?,
            documentID: String,
            navigationRevision: UInt64 = 0
        ) {
            guard let oneBasedLine, oneBasedLine > 0, let textView else { return }
            let key = FileEditorLineTarget.key(
                documentID: documentID,
                line: oneBasedLine,
                navigationRevision: navigationRevision
            )
            guard key != lastScrollKey else { return }
            lastScrollKey = key
            let range = FileLineNavigation.range(forOneBasedLine: oneBasedLine, in: textView.string)
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            DispatchQueue.main.async { [weak textView] in
                textView?.scrollRangeToVisible(range)
                textView?.showFindIndicator(for: range)
            }
        }

        func importImages(_ imports: [MarkdownImageImport], at requestedRange: NSRange) {
            guard let markdownURL else { return }
            let workspaceRoot = workspaceRoot
            let previousImport = importTask
            importTask = Task { [weak self] in
                if let previousImport { await previousImport.value }
                guard !Task.isCancelled else { return }
                let batch = await Task.detached(priority: .userInitiated) {
                    MarkdownAssetStore.importImages(
                        imports,
                        markdownURL: markdownURL,
                        workspaceRoot: workspaceRoot
                    )
                }.value
                guard !Task.isCancelled, let self, let textView = self.textView else { return }
                if !batch.insertions.isEmpty {
                    let source = textView.string
                    let nsSource = source as NSString
                    let location = min(max(0, requestedRange.location), nsSource.length)
                    let length = min(max(0, requestedRange.length), nsSource.length - location)
                    let range = NSRange(location: location, length: length)
                    let insertion = MarkdownImageInsertion.text(
                        snippets: batch.insertions.map(\.markdown),
                        source: source,
                        range: range
                    )
                    textView.insertText(insertion, replacementRange: range)
                }
                if !batch.errors.isEmpty {
                    self.onError?(batch.errors.joined(separator: " "))
                }
            }
        }

        func chooseImages(at range: NSRange) {
            let panel = NSOpenPanel()
            panel.title = "Add images to Markdown"
            panel.prompt = "Add"
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            guard panel.runModal() == .OK else { return }
            importImages(panel.urls.map(MarkdownImageImport.file), at: range)
        }

    }
}

/// Editable, styled Markdown with native selection, undo, find, contextual
/// editing, image paste/drop, and trackpad/Command-scroll magnification.
struct MarkdownRenderedEditor: NSViewRepresentable {
    @Binding var text: String
    let markdownURL: URL
    let workspaceRoot: URL?
    @Binding var zoom: CGFloat
    let targetLine: Int?
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, zoom: $zoom)
    }

    func makeNSView(context: Context) -> MarkdownMagnifyingScrollView {
        let scrollView = MarkdownMagnifyingScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.65
        scrollView.maxMagnification = 2

        let textView = MarkdownNativeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        // Autocorrect is the one AppKit affordance here that mutates text
        // storage rather than presentation, so it can silently rewrite the
        // document — inside fenced code blocks especially. The plain source
        // editor leaves it off; this view must match, or the byte-identity
        // guarantee that makes rendered editing safe no longer holds.
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
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
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 18, height: 20)
        textView.backgroundColor = .textBackgroundColor
        textView.font = .systemFont(ofSize: 15)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 5
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        textView.string = text
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.onImageImports = { [weak coordinator = context.coordinator] imports, range in
            coordinator?.importImages(imports, at: range)
        }
        textView.onChooseImages = { [weak coordinator = context.coordinator] range in
            coordinator?.chooseImages(at: range)
        }

        scrollView.documentView = textView
        scrollView.magnification = zoom
        scrollView.onMagnificationChanged = { [weak coordinator = context.coordinator] value in
            coordinator?.zoom = value
        }
        context.coordinator.textView = textView
        context.coordinator.markdownURL = markdownURL
        context.coordinator.workspaceRoot = workspaceRoot
        context.coordinator.onError = onError
        context.coordinator.scheduleStyling(immediately: true)
        context.coordinator.scrollIfNeeded(to: targetLine)
        return scrollView
    }

    func updateNSView(_ scrollView: MarkdownMagnifyingScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.markdownURL = markdownURL
        coordinator.workspaceRoot = workspaceRoot
        coordinator.onError = onError
        guard let textView = coordinator.textView else { return }

        if textView.string != text {
            let selection = textView.selectedRange()
            coordinator.isApplyingExternalValue = true
            textView.string = text
            let location = min(selection.location, (text as NSString).length)
            let length = min(selection.length, (text as NSString).length - location)
            textView.setSelectedRange(NSRange(location: location, length: length))
            coordinator.isApplyingExternalValue = false
            coordinator.scheduleStyling(immediately: true)
        }
        if abs(scrollView.magnification - zoom) > 0.001 {
            let center = textView.convert(
                NSPoint(x: scrollView.contentView.bounds.midX, y: scrollView.contentView.bounds.midY),
                from: scrollView.contentView
            )
            scrollView.setMagnification(zoom, centeredAt: center)
        }
        // SwiftUI can install the representable after NSTextView has already
        // kept its 640-point seed frame. Width tracking then follows that stale
        // document width rather than the live pane, so source lines paint past
        // the clip view. Reconcile here as well as during NSScrollView tiling so
        // external zoom changes and the first representable update both reflow.
        scrollView.reflowDocumentWidth()
        coordinator.scrollIfNeeded(to: targetLine)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var zoom: CGFloat
        weak var textView: MarkdownNativeTextView?
        var markdownURL: URL?
        var workspaceRoot: URL?
        var onError: ((String) -> Void)?
        var isApplyingExternalValue = false
        private var styleTask: Task<Void, Never>?
        private var importTask: Task<Void, Never>?
        private var lastScrollKey: String?

        init(text: Binding<String>, zoom: Binding<CGFloat>) {
            _text = text
            _zoom = zoom
        }

        deinit {
            styleTask?.cancel()
            importTask?.cancel()
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalValue,
                  let textView = notification.object as? MarkdownNativeTextView else { return }
            text = textView.string
            scheduleStyling(immediately: false)
        }

        func scrollIfNeeded(to oneBasedLine: Int?) {
            guard let oneBasedLine, oneBasedLine > 0, let textView else { return }
            let key = "\(markdownURL?.path ?? "")|\(oneBasedLine)|\(textView.string.utf8.count)"
            guard key != lastScrollKey else { return }
            lastScrollKey = key
            let range = FileLineNavigation.range(forOneBasedLine: oneBasedLine, in: textView.string)
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            DispatchQueue.main.async { [weak textView] in
                textView?.scrollRangeToVisible(range)
                textView?.showFindIndicator(for: range)
            }
        }

        func scheduleStyling(immediately: Bool) {
            styleTask?.cancel()
            guard let textView else { return }
            let source = textView.string
            styleTask = Task { [weak self, weak textView] in
                if !immediately {
                    try? await Task.sleep(for: .milliseconds(70))
                }
                guard !Task.isCancelled else { return }
                let spans = await Task.detached(priority: .utility) {
                    MarkdownEditingStyle.spans(in: source)
                }.value
                guard !Task.isCancelled,
                      let self,
                      let textView,
                      textView.string == source else { return }
                self.apply(spans, to: textView)
            }
        }

        func importImages(_ imports: [MarkdownImageImport], at requestedRange: NSRange) {
            guard let markdownURL else { return }
            let workspaceRoot = workspaceRoot
            // Preserve every paste/drop and serialize writes so rapid imports
            // cannot race for the same unique filename.
            let previousImport = importTask
            importTask = Task { [weak self] in
                if let previousImport { await previousImport.value }
                guard !Task.isCancelled else { return }
                let batch = await Task.detached(priority: .userInitiated) {
                    MarkdownAssetStore.importImages(
                        imports,
                        markdownURL: markdownURL,
                        workspaceRoot: workspaceRoot
                    )
                }.value
                guard !Task.isCancelled, let self, let textView = self.textView else { return }
                if !batch.insertions.isEmpty {
                    let safeLocation = min(requestedRange.location, (textView.string as NSString).length)
                    let safeLength = min(
                        requestedRange.length,
                        (textView.string as NSString).length - safeLocation
                    )
                    let range = NSRange(location: safeLocation, length: safeLength)
                    let insertion = MarkdownImageInsertion.text(
                        snippets: batch.insertions.map(\.markdown),
                        source: textView.string,
                        range: range
                    )
                    textView.insertText(insertion, replacementRange: range)
                }
                if !batch.errors.isEmpty {
                    self.onError?(batch.errors.joined(separator: " "))
                }
            }
        }

        func chooseImages(at range: NSRange) {
            let panel = NSOpenPanel()
            panel.title = "Add images to Markdown"
            panel.prompt = "Add"
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            guard panel.runModal() == .OK else { return }
            importImages(panel.urls.map(MarkdownImageImport.file), at: range)
        }

        private func apply(_ spans: [MarkdownEditingStyle.Span], to textView: NSTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            for key in [
                NSAttributedString.Key.font,
                .foregroundColor,
                .backgroundColor,
                .underlineStyle,
                .obliqueness,
                .paragraphStyle,
            ] {
                layoutManager.removeTemporaryAttribute(key, forCharacterRange: fullRange)
            }

            let bodySize: CGFloat = 15
            for span in spans where NSMaxRange(span.range) <= fullRange.length {
                switch span.role {
                case let .heading(level):
                    let sizes: [CGFloat] = [0, 30, 25, 21, 18, 16, 15]
                    layoutManager.addTemporaryAttribute(
                        .font,
                        value: NSFont.systemFont(ofSize: sizes[min(6, level)], weight: level <= 2 ? .bold : .semibold),
                        forCharacterRange: span.range
                    )
                case .quote:
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, forCharacterRange: span.range)
                    layoutManager.addTemporaryAttribute(.obliqueness, value: 0.12, forCharacterRange: span.range)
                case .codeBlock:
                    layoutManager.addTemporaryAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), forCharacterRange: span.range)
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.labelColor, forCharacterRange: span.range)
                    layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.controlBackgroundColor, forCharacterRange: span.range)
                case .bold:
                    layoutManager.addTemporaryAttribute(.font, value: NSFont.systemFont(ofSize: bodySize, weight: .semibold), forCharacterRange: span.range)
                case .italic:
                    layoutManager.addTemporaryAttribute(.obliqueness, value: 0.16, forCharacterRange: span.range)
                case .inlineCode:
                    layoutManager.addTemporaryAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), forCharacterRange: span.range)
                    layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.controlBackgroundColor, forCharacterRange: span.range)
                case .link:
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.linkColor, forCharacterRange: span.range)
                    layoutManager.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: span.range)
                case .listMarker:
                    layoutManager.addTemporaryAttribute(
                        .font,
                        value: NSFont.systemFont(ofSize: bodySize, weight: .semibold),
                        forCharacterRange: span.range
                    )
                    layoutManager.addTemporaryAttribute(
                        .foregroundColor,
                        value: NSColor.controlAccentColor,
                        forCharacterRange: span.range
                    )
                case .centered:
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = .center
                    paragraph.lineSpacing = 3
                    paragraph.paragraphSpacing = 5
                    layoutManager.addTemporaryAttribute(.paragraphStyle, value: paragraph, forCharacterRange: span.range)
                case .syntax:
                    // Default mode reads like a document: syntax occupies an
                    // effectively zero-width run while the source stays exact
                    // underneath. The toolbar's source toggle is the explicit
                    // escape hatch for editing delimiters and HTML attributes.
                    layoutManager.addTemporaryAttribute(.font, value: NSFont.systemFont(ofSize: 0.1), forCharacterRange: span.range)
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: span.range)
                }
            }
            // Temporary font attributes affect glyph metrics only after the
            // layout pass is invalidated. Without this, invisible delimiters
            // can still wrap visible text at narrow panel widths.
            layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
            if let container = textView.textContainer {
                layoutManager.ensureLayout(for: container)
            }
        }
    }
}

final class MarkdownMagnifyingScrollView: NSScrollView {
    var onMagnificationChanged: ((CGFloat) -> Void)?

    override func tile() {
        super.tile()
        reflowDocumentWidth()
    }

    /// Keep the editable Markdown document exactly as wide as the visible
    /// viewport in document coordinates. `contentView.bounds` already accounts
    /// for NSScrollView magnification, so this preserves zoom while ensuring
    /// paragraphs rewrap instead of disappearing beyond a narrow split pane.
    func reflowDocumentWidth() {
        guard let textView = documentView as? NSTextView else { return }
        let width = contentView.bounds.width
        guard width.isFinite, width > 0 else { return }

        if abs(textView.frame.width - width) > 0.5 {
            var frame = textView.frame
            frame.size.width = width
            textView.frame = frame
        }

        guard let container = textView.textContainer else { return }
        let containerWidth = max(1, width - (textView.textContainerInset.width * 2))
        guard abs(container.containerSize.width - containerWidth) > 0.5 else { return }
        container.containerSize = NSSize(
            width: containerWidth,
            height: container.containerSize.height
        )
        if let textLayoutManager = textView.textLayoutManager {
            // Keep the whole-file source editor on TextKit 2. Asking a TextKit
            // 2 view for its legacy layout manager silently downgrades it.
            textLayoutManager.textViewportLayoutController.layoutViewport()
        } else if let layoutManager = textView.layoutManager {
            let range = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.ensureLayout(for: container)
        }
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        reflowDocumentWidth()
        onMagnificationChanged?(magnification)
    }

    override func scrollWheel(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        guard let target = MarkdownWheelZoom.target(
            current: magnification,
            scrollingDeltaY: event.scrollingDeltaY,
            scrollingDeltaX: event.scrollingDeltaX
        ) else { return }
        let center = documentView?.convert(event.locationInWindow, from: nil)
            ?? NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(target, centeredAt: center)
        reflowDocumentWidth()
        onMagnificationChanged?(target)
    }
}

enum MarkdownWheelZoom {
    static func target(
        current: CGFloat,
        scrollingDeltaY: CGFloat,
        scrollingDeltaX: CGFloat
    ) -> CGFloat? {
        let delta = scrollingDeltaY == 0 ? scrollingDeltaX : scrollingDeltaY
        guard delta.isFinite, delta != 0 else { return nil }
        let target = MarkdownPreviewLayout.clampedZoom(current + delta * 0.01)
        return abs(target - current) > 0.001 ? target : nil
    }
}

/// SwiftUI's `MagnificationGesture` handles trackpad pinches but does not see a
/// Command-mouse-wheel gesture. This transparent AppKit bridge observes only
/// Command-scroll events whose pointer is inside the rendered Markdown pane;
/// every ordinary scroll continues through the enclosing SwiftUI ScrollView.
struct MarkdownCommandScrollZoomBridge: NSViewRepresentable {
    @Binding var zoom: CGFloat

    func makeNSView(context: Context) -> MarkdownCommandScrollMonitorView {
        MarkdownCommandScrollMonitorView()
    }

    func updateNSView(_ view: MarkdownCommandScrollMonitorView, context: Context) {
        view.currentZoom = zoom
        view.onZoom = { zoom = $0 }
    }
}

@MainActor
final class MarkdownCommandScrollMonitorView: NSView {
    var currentZoom: CGFloat = 1
    var onZoom: (CGFloat) -> Void = { _ in }
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                  let target = MarkdownWheelZoom.target(
                      current: self.currentZoom,
                      scrollingDeltaY: event.scrollingDeltaY,
                      scrollingDeltaX: event.scrollingDeltaX
                  ) else { return event }
            self.currentZoom = target
            self.onZoom(target)
            return nil
        }
    }

    private func removeMonitor() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}

enum MarkdownListContinuation: Equatable, Sendable {
    case continueWith(String)
    case exitList

    static func action(for line: String) -> MarkdownListContinuation? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        if let expression = try? NSRegularExpression(
            pattern: #"^([ \t]*)([-+*])([ \t]+)(?:\[([ xX])\]([ \t]+))?(.*)$"#
        ), let match = expression.firstMatch(in: line, range: range) {
            let body = substring(match.range(at: 6), in: line)
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .exitList
            }
            let indent = substring(match.range(at: 1), in: line)
            let marker = substring(match.range(at: 2), in: line)
            let spacing = substring(match.range(at: 3), in: line)
            if match.range(at: 4).location != NSNotFound {
                return .continueWith(
                    indent + marker + spacing + "[ ]" + substring(match.range(at: 5), in: line)
                )
            }
            return .continueWith(indent + marker + spacing)
        }

        if let expression = try? NSRegularExpression(
            pattern: #"^([ \t]*)([0-9]+)([.)])([ \t]+)(.*)$"#
        ), let match = expression.firstMatch(in: line, range: range) {
            let body = substring(match.range(at: 5), in: line)
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .exitList
            }
            let current = Int(substring(match.range(at: 2), in: line)) ?? 0
            return .continueWith(
                substring(match.range(at: 1), in: line)
                    + String(current + 1)
                    + substring(match.range(at: 3), in: line)
                    + substring(match.range(at: 4), in: line)
            )
        }
        return nil
    }

    private static func substring(_ range: NSRange, in value: String) -> String {
        guard range.location != NSNotFound else { return "" }
        return (value as NSString).substring(with: range)
    }
}

@MainActor
final class MarkdownNativeTextView: NSTextView {
    var onImageImports: (([MarkdownImageImport], NSRange) -> Void)?
    var onChooseImages: ((NSRange) -> Void)?

    static func wholeFileSourceEditor() -> MarkdownNativeTextView {
        MarkdownNativeTextView(usingTextLayoutManager: true)
    }

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0 else {
            super.insertNewline(sender)
            return
        }
        let source = string as NSString
        let paragraph = source.paragraphRange(for: selection)
        let contentEnd = paragraph.location + paragraph.length
            - lineTerminatorLength(in: source, paragraph: paragraph)
        guard selection.location <= contentEnd else {
            super.insertNewline(sender)
            return
        }
        let prefixRange = NSRange(
            location: paragraph.location,
            length: selection.location - paragraph.location
        )
        let lineBeforeCaret = source.substring(with: prefixRange)
        switch MarkdownListContinuation.action(for: lineBeforeCaret) {
        case let .continueWith(prefix):
            insertText("\n" + prefix, replacementRange: selection)
        case .exitList where selection.location == contentEnd:
            insertText("\n", replacementRange: paragraph)
        case .exitList, .none:
            super.insertNewline(sender)
        }
    }

    private func lineTerminatorLength(in source: NSString, paragraph: NSRange) -> Int {
        guard paragraph.length > 0 else { return 0 }
        let last = source.character(at: NSMaxRange(paragraph) - 1)
        guard last == 0x0A || last == 0x0D else { return 0 }
        if paragraph.length > 1, last == 0x0A,
           source.character(at: NSMaxRange(paragraph) - 2) == 0x0D {
            return 2
        }
        return 1
    }

    override func paste(_ sender: Any?) {
        let imports = MarkdownPasteboardReader.imports(from: .general)
        guard !imports.isEmpty else {
            super.paste(sender)
            return
        }
        onImageImports?(imports, selectedRange())
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        MarkdownPasteboardReader.containsImages(sender.draggingPasteboard)
            ? .copy
            : super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let imports = MarkdownPasteboardReader.imports(from: sender.draggingPasteboard)
        guard !imports.isEmpty else { return super.performDragOperation(sender) }
        onImageImports?(imports, insertionRange(for: sender))
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        addItem("Bold", action: #selector(formatBold(_:)), to: menu)
        addItem("Italic", action: #selector(formatItalic(_:)), to: menu)
        addItem("Inline Code", action: #selector(formatInlineCode(_:)), to: menu)
        addItem("Link", action: #selector(formatLink(_:)), to: menu)
        addItem("Heading", action: #selector(formatHeading(_:)), to: menu)
        addItem("Bulleted List", action: #selector(formatBulletedList(_:)), to: menu)
        menu.addItem(.separator())
        addItem("Insert Image…", action: #selector(chooseImage(_:)), to: menu)
        return menu
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func formatBold(_ sender: Any?) {
        wrapSelection(prefix: "**", suffix: "**", placeholder: "bold text")
    }

    @objc private func formatItalic(_ sender: Any?) {
        wrapSelection(prefix: "*", suffix: "*", placeholder: "italic text")
    }

    @objc private func formatInlineCode(_ sender: Any?) {
        wrapSelection(prefix: "`", suffix: "`", placeholder: "code")
    }

    @objc private func formatLink(_ sender: Any?) {
        let range = selectedRange()
        let selected = range.length > 0 ? (string as NSString).substring(with: range) : "link text"
        let replacement = "[\(selected)](https://)"
        insertText(replacement, replacementRange: range)
        if range.length == 0 {
            setSelectedRange(NSRange(location: range.location + 1, length: selected.utf16.count))
        } else {
            setSelectedRange(NSRange(location: range.location + selected.utf16.count + 3, length: 8))
        }
    }

    @objc private func formatHeading(_ sender: Any?) {
        transformSelectedLines { line in
            let expression = try? NSRegularExpression(pattern: #"^#{1,6}[ \t]+"#)
            let range = NSRange(location: 0, length: (line as NSString).length)
            if expression?.firstMatch(in: line, range: range) != nil {
                return expression?.stringByReplacingMatches(in: line, range: range, withTemplate: "") ?? line
            }
            return line.isEmpty ? line : "## \(line)"
        }
    }

    @objc private func formatBulletedList(_ sender: Any?) {
        let paragraphRange = (string as NSString).paragraphRange(for: selectedRange())
        let source = (string as NSString).substring(with: paragraphRange)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let nonempty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let alreadyBulleted = !nonempty.isEmpty && nonempty.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
        }
        transformSelectedLines { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            if alreadyBulleted,
               let marker = line.range(of: "- ") {
                return String(line[..<marker.lowerBound]) + line[marker.upperBound...]
            }
            return "- \(line)"
        }
    }

    @objc private func chooseImage(_ sender: Any?) {
        onChooseImages?(selectedRange())
    }

    private func wrapSelection(prefix: String, suffix: String, placeholder: String) {
        let range = selectedRange()
        let selected = range.length > 0 ? (string as NSString).substring(with: range) : placeholder
        insertText(prefix + selected + suffix, replacementRange: range)
        setSelectedRange(NSRange(location: range.location + prefix.utf16.count, length: selected.utf16.count))
    }

    private func transformSelectedLines(_ transform: (String) -> String) {
        let range = (string as NSString).paragraphRange(for: selectedRange())
        let source = (string as NSString).substring(with: range)
        let replacement = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { transform(String($0)) }
            .joined(separator: "\n")
        insertText(replacement, replacementRange: range)
        setSelectedRange(NSRange(location: range.location, length: replacement.utf16.count))
    }

    private func insertionRange(for sender: any NSDraggingInfo) -> NSRange {
        let local = convert(sender.draggingLocation, from: nil)
        // NSTextView owns the TextKit-version-specific hit testing. Accessing
        // the legacy `layoutManager` from a TextKit 2 view forces AppKit to
        // fall back to TextKit 1, so keep image-drop positioning on this
        // version-neutral API.
        let character = min(characterIndexForInsertion(at: local), (string as NSString).length)
        return NSRange(location: character, length: 0)
    }
}

@MainActor
private enum MarkdownPasteboardReader {
    static func containsImages(_ pasteboard: NSPasteboard) -> Bool {
        let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tif", "tiff"])
        if let values = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], values.contains(where: { imageExtensions.contains($0.pathExtension.lowercased()) }) {
            return true
        }
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    static func imports(from pasteboard: NSPasteboard) -> [MarkdownImageImport] {
        let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tif", "tiff"])
        if let values = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            let files = values.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            if !files.isEmpty { return files.map(MarkdownImageImport.file) }
        }

        if let png = pasteboard.data(forType: .png), !png.isEmpty {
            return [.data(png, suggestedName: "pasted-image", fileExtension: "png")]
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return [] }
        return [.data(png, suggestedName: "pasted-image", fileExtension: "png")]
    }
}

/// Native rich-text editor for Office Open XML documents. NSTextView preserves
/// formatting and provides undo, find, selection, spell checking, and familiar
/// macOS editing semantics; the surrounding neutral canvas gives the document
/// a quiet page-like surface rather than another dense application toolbar.
struct RichDocumentEditor: NSViewRepresentable {
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
