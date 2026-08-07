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
        // Wikilinks: the name reads as a link, the double brackets collapse
        // like any other syntax until the cursor's line reveals them.
        collect(
            #"(\[\[)([^\[\]\r\n]+)(\]\])"#,
            role: { _ in .link },
            contentGroup: 2,
            syntaxGroups: [1, 3]
        )
        // Task markers: the bracket group reads as a control (click toggles it
        // via MarkdownTaskToggle); accent + semibold matches list markers.
        collect(
            #"(?m)^[ \t]*(?:[-*+])[ \t]+(\[(?: |x|X)\])(?=[ \t])"#,
            role: { _ in .listMarker },
            contentGroup: 1
        )
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
        // A reference that occupies a whole line is painted as a picture by the
        // layout manager, so its source collapses completely — alt text
        // included. Without this the alt text renders as a stray link caption
        // underneath the image it names. Appended last so it outranks the link
        // rule that also matched it.
        for line in MarkdownInlineImages.lines(in: source) {
            for reference in line.references {
                result.append(Span(range: reference.range, role: .syntax))
            }
        }

        // Several semantic recognizers intentionally overlap (for example an
        // `<em>` pair is found both by the emphasis rule and by the generic
        // tag rule). Apply each identical style/range once so TextKit does not
        // redo attribute work while scrolling a Markdown document.
        var seen: Set<Span> = []
        var unique: [Span] = []
        unique.reserveCapacity(min(result.count, 20_000))
        for span in result where seen.insert(span).inserted {
            unique.append(span)
            if unique.count == 20_000 { break }
        }
        return unique
    }

    static let bodySize: CGFloat = 16

    /// The reading face: the system serif (New York) at body size, LessWrong-
    /// style. Falls back to the plain system font if the serif design is
    /// unavailable (it ships on every supported macOS).
    static func bodyFont(size: CGFloat = bodySize, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif),
              let serif = NSFont(descriptor: descriptor, size: size) else { return base }
        return serif
    }

    /// Trait composition (2026-08-06 spec 1a): emphasis composes onto the face
    /// already resolved at that range — serif bold in body, sans bold in a
    /// table cell, bold+italic nesting — instead of stamping a static font.
    static func composed(base: NSFont, bold: Bool = false, italic: Bool = false) -> NSFont {
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    static var bodyParagraphStyle: NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        // ~1.5 effective leading on the 16pt serif — the reading rhythm the
        // whole treatment hangs on.
        paragraph.lineSpacing = 6
        paragraph.paragraphSpacing = 10
        return paragraph
    }

    /// What every character looks like before a role claims it. A styling pass
    /// resets to this first, so removing emphasis restores plain body text
    /// rather than leaving the old attributes behind.
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: bodyFont(),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: bodyParagraphStyle,
        ]
    }

    /// The attributes a role paints with.
    ///
    /// These describe presentation only. They are applied to the text storage's
    /// *attributes*, never its characters, so the document's bytes stay exactly
    /// what was typed.
    static func attributes(for role: Role) -> [NSAttributedString.Key: Any] {
        switch role {
        case let .heading(level):
            // Headings stay sans against the serif body — the same contrast
            // LessWrong plays — with tightened tracking on the display sizes.
            let sizes: [CGFloat] = [0, 28, 23, 20, 17, 16, 15]
            let clamped = min(6, max(1, level))
            var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(
                ofSize: sizes[clamped],
                weight: clamped <= 2 ? .bold : .semibold
            )]
            if clamped <= 2 { attributes[.kern] = -0.3 }
            return attributes
        case .quote:
            // Full-size serif italic (not dimmed): a quotation reads as prose
            // with the drawn accent bar carrying the demarcation.
            return [.font: composed(base: bodyFont(), italic: true)]
        case .codeBlock:
            return [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        case .bold:
            return [.font: composed(base: bodyFont(), bold: true)]
        case .italic:
            return [.font: composed(base: bodyFont(), italic: true)]
        case .inlineCode:
            return [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .backgroundColor: NSColor.controlBackgroundColor,
            ]
        case .link:
            return [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        case .listMarker:
            return [
                .font: NSFont.systemFont(ofSize: bodySize, weight: .semibold),
                .foregroundColor: NSColor.controlAccentColor,
            ]
        case .centered:
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = 5
            return [.paragraphStyle: paragraph]
        case .syntax:
            // The document reads like prose: syntax occupies an effectively
            // zero-width run while the source stays exact underneath. The
            // cursor's paragraph reveals its marks (see `attributes(for:revealed:)`);
            // the toolbar's source toggle remains for bulk syntax surgery.
            return [
                .font: NSFont.systemFont(ofSize: 0.1),
                .foregroundColor: NSColor.clear,
            ]
        }
    }

    /// Role attributes with cursor-line reveal. Only `.syntax` changes:
    /// revealed marks render dimmed at near-body size so the line under the
    /// cursor reads as editable Markdown, Obsidian-style, while every other
    /// paragraph keeps its marks collapsed.
    static func attributes(for role: Role, revealed: Bool) -> [NSAttributedString.Key: Any] {
        guard revealed, role == .syntax else { return attributes(for: role) }
        return [
            .font: NSFont.systemFont(ofSize: max(11, bodySize * 0.85)),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
    }
}

/// Range arithmetic for the incremental style pass: a changed paragraph that
/// touches a table grows to cover the whole table region (its geometry is
/// measured as a unit), and overlapping results merge so a range is never
/// painted twice in one pass.
enum MarkdownIncrementalStyle {
    static func rangesToRestyle(
        changed: [NSRange],
        tables: [MarkdownTableRegion],
        in source: NSString
    ) -> [NSRange] {
        var extended = changed.map { range in
            tables.reduce(range) { widened, table in
                NSIntersectionRange(widened, table.range).length > 0
                    ? NSUnionRange(widened, table.range)
                    : widened
            }
        }
        extended.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in extended {
            if let last = merged.last, NSMaxRange(last) >= range.location {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

/// Everything one debounced styling pass needs, computed off the main actor in
/// a single scan of the source.
struct MarkdownLiveStyleScan: Sendable {
    let spans: [MarkdownEditingStyle.Span]
    let tables: [MarkdownTableRegion]
    let thematicBreaks: [NSRange]

    nonisolated init(source: String) {
        spans = MarkdownEditingStyle.spans(in: source)
        tables = MarkdownTableRegions.scan(source)
        thematicBreaks = MarkdownThematicBreaks.scan(source)
    }
}

/// Resolves the destination of the Markdown link under a character index.
///
/// The rendered document used SwiftUI's `openURL` for this. A text view has no
/// equivalent, and a real `.link` attribute would have to live in the text
/// storage, so the destination is read back out of the source instead — which
/// also means the link the user follows is literally the link in the file.
enum MarkdownLinkTargets {
    private static let wikiPattern = #"\[\[([^\[\]\r\n]+)\]\]"#
    private static let inlinePattern = #"(!?)\[([^\]\r\n]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"\r\n]*")?\s*\)"#
    private static let anchorPattern = #"(?i)<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>.*?</a\s*>"#
    private static let barePattern = #"(?i)\bhttps?://[^\s<>()\[\]"']+"#

    /// The scheme wikilink destinations travel under: the name rides in the
    /// URL path so case and spaces survive the round trip.
    static let wikiScheme = "kaisola-wiki"

    static func destination(at characterIndex: Int, in source: String) -> String? {
        let nsSource = source as NSString
        guard characterIndex >= 0, characterIndex <= nsSource.length else { return nil }
        // Bound the scan to the paragraph so a long document stays cheap.
        let paragraph = nsSource.paragraphRange(
            for: NSRange(location: min(characterIndex, max(0, nsSource.length - 1)), length: 0)
        )
        guard paragraph.length > 0 else { return nil }
        let local = characterIndex - paragraph.location
        let text = nsSource.substring(with: paragraph)
        let range = NSRange(location: 0, length: (text as NSString).length)

        for (pattern, group) in [(wikiPattern, 1), (inlinePattern, 3), (anchorPattern, 1), (barePattern, 0)] {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.dotMatchesLineSeparators]
            ) else { continue }
            for match in expression.matches(in: text, range: range)
            where NSLocationInRange(local, match.range)
                || local == NSMaxRange(match.range) {
                // An image is not a link; following one would open the picture
                // the reader is already looking at.
                if pattern == inlinePattern,
                   (text as NSString).substring(with: match.range(at: 1)) == "!" { continue }
                let destination = (text as NSString).substring(with: match.range(at: group))
                if pattern == wikiPattern {
                    let encoded = destination.addingPercentEncoding(
                        withAllowedCharacters: .urlPathAllowed
                    ) ?? destination
                    return wikiScheme + ":/" + encoded
                }
                if !destination.isEmpty { return destination }
            }
        }
        return nil
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
            && scrollView.documentVisibleRect.height > 0
            && !textView.string.isEmpty
    }

    /// How far down its scrollable range the view currently sits, 0...1.
    static func scrollFraction(in textView: NSTextView, scrollView: NSScrollView) -> Double {
        let scrollable = scrollableHeight(textView, scrollView)
        guard scrollable > 0 else { return 0 }
        return min(1, max(0, Double(offset(in: scrollView) / scrollable)))
    }

    /// Put `fraction` of the scrollable range above the viewport.
    static func scroll(to fraction: Double, in textView: NSTextView, scrollView: NSScrollView) {
        let scrollable = scrollableHeight(textView, scrollView)
        scroll(to: CGFloat(min(1, max(0, fraction))) * scrollable, in: textView, scrollView: scrollView)
    }

    /// How far the viewport currently sits down the document, in the
    /// document's own coordinates.
    ///
    /// Deliberately not `contentView.bounds.origin`. The Markdown editor's
    /// clip view places the document view at a large negative frame origin, so
    /// the clip's own bounds origin is nowhere near zero at the top of the
    /// file — a caller testing `> 0` to mean "scrolled" is answered `false` at
    /// every position, which is precisely how the viewport-pinning machinery
    /// came to be dead code in the running app.
    static func offset(in scrollView: NSScrollView) -> CGFloat {
        scrollView.documentVisibleRect.origin.y
    }

    /// Scroll so `offset` in document coordinates sits at the top of the
    /// viewport. `NSView.scroll(_:)` is coordinate-space safe in a way that
    /// scrolling the clip view by hand is not.
    static func scroll(to offset: CGFloat, in textView: NSTextView, scrollView: NSScrollView) {
        textView.scroll(NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private static func scrollableHeight(_ textView: NSTextView, _ scrollView: NSScrollView) -> CGFloat {
        max(0, textView.bounds.height - scrollView.documentVisibleRect.height)
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
/// The whole Markdown document as one editable, styled text view.
///
/// The document reads like prose — headings, emphasis, code, and links are
/// styled where they sit and their delimiters collapse — while the text storage
/// holds the file's exact Markdown. Styling is applied as TextKit *temporary*
/// attributes and images are painted by the layout manager, so neither the
/// presentation nor the images ever reach the text storage. What is typed is
/// what is saved; there is no serializer in the write path to lose a relative
/// image link or a line ending.
struct MarkdownRenderedEditor: NSViewRepresentable {
    @Binding var text: String
    let markdownURL: URL
    let workspaceRoot: URL?
    @Binding var zoom: CGFloat
    let targetLine: Int?
    let onError: (String) -> Void
    /// Identity for remembered scroll positions. Empty opts out.
    var documentID: String = ""
    var scrollMemory: FilePreviewTextScrollMemory? = nil
    /// Bumped by the workspace watcher. Only re-resolves images; an unchanged
    /// image file keeps its decoded bytes and its drawn size.
    var imageRevision: Int = 0
    var navigationRevision: UInt64 = 0
    var automaticallyFocus = false
    var onOpenLink: ((URL) -> Void)? = nil

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
        scrollView.minMagnification = MarkdownPreviewLayout.minimumZoom
        scrollView.maxMagnification = MarkdownPreviewLayout.maximumZoom

        // TextKit 1, assembled by hand so the document can carry a layout
        // manager that draws inline images. An `NSTextAttachment` would need a
        // real `U+FFFC` character in the storage, and putting rendering
        // artifacts into the document is exactly how a previous version of this
        // surface deleted relative images from saved files.
        let storage = NSTextStorage()
        let layoutManager = MarkdownInlineImageLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.delegate = context.coordinator

        let textView = MarkdownNativeTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480),
            textContainer: container
        )
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
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
        textView.textContainerInset = NSSize(width: 18, height: 20)
        textView.backgroundColor = .textBackgroundColor
        textView.font = .systemFont(ofSize: MarkdownEditingStyle.bodySize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 5
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: MarkdownEditingStyle.bodySize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        textView.setAccessibilityLabel("Markdown document")
        textView.string = text
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.onImageImports = { [weak coordinator = context.coordinator] imports, range in
            coordinator?.importImages(imports, at: range)
        }
        textView.onChooseImages = { [weak coordinator = context.coordinator] range in
            coordinator?.chooseImages(at: range)
        }
        textView.onFollowLink = { [weak coordinator = context.coordinator] index in
            coordinator?.followLink(at: index)
        }

        scrollView.documentView = textView
        scrollView.magnification = zoom
        scrollView.onMagnificationChanged = { [weak coordinator = context.coordinator] value in
            coordinator?.zoom = value
        }
        scrollView.onDocumentWidthChanged = { [weak coordinator = context.coordinator] in
            coordinator?.restyleIfDocumentWidthChanged()
        }
        context.coordinator.attach(textView: textView, scrollView: scrollView)
        context.coordinator.markdownURL = markdownURL
        context.coordinator.workspaceRoot = workspaceRoot
        context.coordinator.onError = onError
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.adopt(documentID: documentID, scrollMemory: scrollMemory)
        context.coordinator.scheduleStyling(immediately: true)
        context.coordinator.refreshImages(revision: imageRevision, force: true)
        context.coordinator.scrollIfNeeded(to: targetLine, revision: navigationRevision)
        if automaticallyFocus {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: MarkdownMagnifyingScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.markdownURL = markdownURL
        coordinator.workspaceRoot = workspaceRoot
        coordinator.onError = onError
        coordinator.onOpenLink = onOpenLink
        guard let textView = coordinator.textView else { return }
        coordinator.adopt(documentID: documentID, scrollMemory: scrollMemory)

        // The load-bearing guard. Saving, autosaving, journaling, and
        // reconciling an unchanged file all re-run this body with the string
        // already on screen; swapping the storage there collapses layout and
        // throws the viewport back to line 1.
        switch MarkdownEditorTextSync.plan(
            current: textView.string,
            incoming: text,
            selection: textView.selectedRange()
        ) {
        case .unchanged:
            break
        case let .replace(selection):
            coordinator.replaceText(with: text, restoring: selection)
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
        coordinator.refreshImages(revision: imageRevision, force: false)
        coordinator.restyleIfDocumentWidthChanged()
        coordinator.scrollIfNeeded(to: targetLine, revision: navigationRevision)
    }

    static func dismantleNSView(
        _ scrollView: MarkdownMagnifyingScrollView,
        coordinator: Coordinator
    ) {
        coordinator.recordScrollPosition()
    }

    @MainActor
    // Layout callbacks arrive on the main thread with the text view, but
    // `NSLayoutManagerDelegate` predates the SDK's actor annotations.
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSLayoutManagerDelegate {
        @Binding var text: String
        @Binding var zoom: CGFloat
        weak var textView: MarkdownNativeTextView?
        private weak var scrollView: NSScrollView?
        var markdownURL: URL?
        var workspaceRoot: URL?
        var onError: ((String) -> Void)?
        var onOpenLink: ((URL) -> Void)?
        var isApplyingExternalValue = false
        /// Guards the attribute pass so a restyle cannot be mistaken for a user
        /// edit and start the save/journal machinery.
        private var isApplyingStyle = false

        /// The paragraphs currently revealing their syntax marks, and the scan
        /// the last styling pass painted from. A selection change diffs the
        /// state and repaints only the changed paragraphs through the cached
        /// scan; the next debounced full pass replaces the cache.
        var revealState: MarkdownRevealState = .none
        private var lastScan: MarkdownLiveStyleScan?

        private func revealed(_ span: MarkdownEditingStyle.Span) -> Bool {
            guard span.role == .syntax else { return false }
            return revealState.activeParagraphs.contains {
                NSIntersectionRange($0, span.range).length > 0
            }
        }
        private var styleTask: Task<Void, Never>?
        /// Container width the current grid was measured against.
        private var styledWidth: CGFloat?
        /// The viewport character a pending text replacement wants back once
        /// the styling pass has given the document its real height.
        private var pendingAnchor: (characterIndex: Int, offset: CGFloat)?
        private var importTask: Task<Void, Never>?
        private var imageTask: Task<Void, Never>?
        private var lastScrollKey: String?
        private var appliedImageRevision: Int?
        private var appliedImageSource: String?
        private var appliedImageWidth: CGFloat?

        // Scroll retention, matching the read-only source surface so the
        // document/source toggle keeps the same text at the top.
        private var scrollMemory: FilePreviewTextScrollMemory?
        private var documentID = ""
        private var pendingRestore = true
        private var programmaticScrollDepth = 0

        init(text: Binding<String>, zoom: Binding<CGFloat>) {
            _text = text
            _zoom = zoom
        }

        deinit {
            styleTask?.cancel()
            importTask?.cancel()
            imageTask?.cancel()
        }

        func attach(textView: MarkdownNativeTextView, scrollView: NSScrollView) {
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

        func adopt(documentID: String, scrollMemory: FilePreviewTextScrollMemory?) {
            self.scrollMemory = scrollMemory
            guard self.documentID != documentID else { return }
            recordScrollPosition()
            self.documentID = documentID
            pendingRestore = true
            DispatchQueue.main.async { [weak self] in self?.restoreScrollPosition() }
        }

        @objc private func viewportDidScroll() {
            recordScrollPosition()
        }

        func recordScrollPosition() {
            guard !pendingRestore, programmaticScrollDepth == 0,
                  let scrollMemory, !documentID.isEmpty,
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
            guard let fraction = scrollMemory?.fraction(for: documentID), fraction > 0 else { return }
            programmaticScrollDepth += 1
            FilePreviewTextScroll.scroll(to: fraction, in: textView, scrollView: scrollView)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let textView = self.textView, let scrollView = self.scrollView,
                   FilePreviewTextScroll.canMeasure(textView, in: scrollView) {
                    FilePreviewTextScroll.scroll(to: fraction, in: textView, scrollView: scrollView)
                }
                self.programmaticScrollDepth -= 1
            }
        }

        /// Replace the whole document (an external reload or a discarded draft)
        /// while keeping the reader roughly where they were.
        func replaceText(with value: String, restoring selection: NSRange) {
            guard let textView else { return }
            // The cached scan describes the text being replaced; a selection
            // change landing between this swap and the debounced rescan (an
            // external reload often arrives together with a line-target
            // navigation) must not paint stale spans — or their stale table
            // ranges — against the new string.
            lastScan = nil
            let previousOrigin = scrollView.map(FilePreviewTextScroll.offset(in:)) ?? 0
            let previousHeight = textView.bounds.height
            let viewportHeight = scrollView?.documentVisibleRect.height ?? 0
            // Taken before the swap, and honoured again after the styling pass
            // below. Replacing the string strips every attribute, so the height
            // measured moments from now is the height of an *unstyled*
            // document — headings at body size, table rows at full height — and
            // restoring a proportion of that throws the reader thousands of
            // points off. The character that was at the top of the viewport is
            // the only anchor that survives a restyle.
            let anchor = viewportAnchor()
            isApplyingExternalValue = true
            programmaticScrollDepth += 1
            textView.string = value
            textView.setSelectedRange(selection)
            isApplyingExternalValue = false
            scheduleStyling(immediately: true)
            refreshImages(revision: appliedImageRevision ?? 0, force: true)
            if let scrollView, previousOrigin > 0 {
                if let container = textView.textContainer {
                    textView.layoutManager?.ensureLayout(for: container)
                }
                let origin = MarkdownEditorScrollRetention.restoredOrigin(
                    previousOrigin: previousOrigin,
                    previousContentHeight: previousHeight,
                    newContentHeight: textView.bounds.height,
                    viewportHeight: viewportHeight
                )
                FilePreviewTextScroll.scroll(to: origin, in: textView, scrollView: scrollView)
            }
            if let anchor, MarkdownEditorScrollRetention.anchorSurvives(
                characterIndex: anchor.characterIndex,
                in: value
            ) {
                pendingAnchor = anchor
            }
            programmaticScrollDepth -= 1
        }

        // MARK: Editing

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalValue, !isApplyingStyle,
                  let textView = notification.object as? MarkdownNativeTextView else { return }
            text = textView.string
            // The cached scan's offsets are stale the moment the text changes;
            // reveal pauses until the debounced rescan lands rather than paint
            // old spans at shifted positions.
            lastScan = nil
            scheduleStyling(immediately: false)
            scheduleImageRefresh()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingStyle, !isApplyingExternalValue,
                  let textView,
                  notification.object as? NSTextView === textView else { return }
            let new = MarkdownRevealState.compute(
                selection: textView.selectedRange(),
                in: textView.string as NSString
            )
            guard new != revealState else { return }
            let changed = MarkdownRevealState.changedRanges(from: revealState, to: new)
            revealState = new
            guard let lastScan, !changed.isEmpty else { return }
            apply(lastScan, to: textView, limitedTo: changed)
        }

        /// `revision` is what makes clicking the same outline row twice work:
        /// the target line has not changed, but the request has.
        func scrollIfNeeded(to oneBasedLine: Int?, revision: UInt64) {
            guard let oneBasedLine, oneBasedLine > 0, let textView else { return }
            let key = "\(markdownURL?.path ?? "")|\(oneBasedLine)|\(revision)"
            guard key != lastScrollKey else { return }
            lastScrollKey = key
            let range = FileLineNavigation.range(forOneBasedLine: oneBasedLine, in: textView.string)
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            // An explicit navigation outranks a remembered position.
            pendingRestore = false
            DispatchQueue.main.async { [weak textView] in
                textView?.scrollRangeToVisible(range)
                textView?.showFindIndicator(for: range)
            }
        }

        func followLink(at characterIndex: Int) {
            guard let textView, let onOpenLink else { return }
            guard let destination = MarkdownLinkTargets.destination(
                at: characterIndex,
                in: textView.string
            ) else { return }
            guard let url = URL(string: destination)
                ?? URL(string: destination.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                ) ?? destination) else { return }
            onOpenLink(url)
        }

        // MARK: Styling

        func scheduleStyling(immediately: Bool) {
            styleTask?.cancel()
            guard let textView else { return }
            let source = textView.string
            styleTask = Task { [weak self, weak textView] in
                if !immediately {
                    try? await Task.sleep(for: .milliseconds(70))
                }
                guard !Task.isCancelled else { return }
                let scan = await Task.detached(priority: .utility) {
                    MarkdownLiveStyleScan(source: source)
                }.value
                guard !Task.isCancelled,
                      let self,
                      let textView,
                      textView.string == source else { return }
                self.apply(scan, to: textView)
            }
        }

        /// Column widths are measured against the pane, so a resize or a zoom
        /// step has to re-align the grid. Ordinary scrolling and typing do not
        /// change the container width and so cost nothing here.
        func restyleIfDocumentWidthChanged() {
            guard let width = textView?.textContainer?.size.width, width > 0 else { return }
            guard styledWidth.map({ abs($0 - width) > 0.5 }) ?? true else { return }
            styledWidth = width
            scheduleStyling(immediately: false)
        }

        /// Paint the document's typography.
        ///
        /// These are real text-storage attributes rather than TextKit
        /// *temporary* attributes. Temporary attributes are documented as not
        /// affecting layout, and in practice a temporary font does not drive
        /// glyph metrics or line height: headings came out body-sized and
        /// "hidden" delimiters kept their full width. That was tolerable when
        /// this editor was a small box inside a separately rendered document.
        /// Now that it *is* the document, the typography has to be real.
        ///
        /// This does not weaken the byte guarantee. Attributes are not
        /// characters: `textView.string` is untouched, and the save path writes
        /// that string. The text view is also `isRichText = false`, so styling
        /// can never be typed, pasted, or copied out of the document either.
        private func apply(
            _ scan: MarkdownLiveStyleScan,
            to textView: NSTextView,
            limitedTo ranges: [NSRange]? = nil
        ) {
            guard let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            guard fullRange.length > 0 else { return }

            // A limited pass repaints only the given paragraph ranges — the
            // cursor-reveal path — widened to whole table regions where they
            // intersect one, so per-cursor-move cost is bounded by paragraph
            // (or table) size, never document size.
            let targets: [NSRange]
            if let ranges {
                let clamped = ranges
                    .map { NSIntersectionRange($0, fullRange) }
                    .filter { $0.length > 0 }
                guard !clamped.isEmpty else { return }
                // Re-clamp after widening: a stale scan's table ranges can
                // reach past the current storage, and setAttributes past the
                // end raises NSRangeException.
                targets = MarkdownIncrementalStyle.rangesToRestyle(
                    changed: clamped,
                    tables: scan.tables,
                    in: storage.string as NSString
                )
                .map { NSIntersectionRange($0, fullRange) }
                .filter { $0.length > 0 }
                guard !targets.isEmpty else { return }
            } else {
                targets = [fullRange]
            }
            lastScan = scan

            // Typography changes the document's height, so pin the character at
            // the top of the viewport and put it back afterwards rather than
            // letting the scroll view keep a now-meaningless pixel offset. A
            // replacement that is still waiting for its real height hands its
            // own anchor over here, because the one this view can read now was
            // measured against unstyled text. Reveal changes heights too, so
            // limited passes anchor the same way.
            let anchor = pendingAnchor ?? viewportAnchor()
            let restoringReplacement = pendingAnchor != nil
            pendingAnchor = nil
            let before = storage.string
            let width = textView.textContainer?.size.width ?? textView.bounds.width
            styledWidth = width

            isApplyingStyle = true
            storage.beginEditing()
            var touchedTables = ranges == nil && !scan.tables.isEmpty
            for target in targets {
                storage.setAttributes(MarkdownEditingStyle.baseAttributes, range: target)
                // Table rows take their base face first so a cell's own emphasis,
                // link, or inline code still wins over it.
                let regions = scan.tables.filter {
                    NSIntersectionRange($0.range, target).length > 0
                }
                if !regions.isEmpty {
                    touchedTables = true
                    MarkdownTableStyler.applyTypography(
                        regions: regions,
                        thematicBreaks: scan.thematicBreaks,
                        to: storage
                    )
                }
                for span in scan.spans where NSMaxRange(span.range) <= fullRange.length {
                    let paint = NSIntersectionRange(span.range, target)
                    guard paint.length > 0 else { continue }
                    switch span.role {
                    case .bold, .italic:
                        // Trait composition (spec 1a): emphasis composes onto
                        // whatever face is already resolved at each position —
                        // serif in body, sans in a table cell, and nested
                        // bold+italic stack because each pass reads the font
                        // the previous one left.
                        var location = paint.location
                        while location < NSMaxRange(paint) {
                            var effective = NSRange(location: location, length: 0)
                            let base = storage.attribute(
                                .font, at: location, effectiveRange: &effective
                            ) as? NSFont ?? MarkdownEditingStyle.bodyFont()
                            let run = NSIntersectionRange(effective, paint)
                            guard run.length > 0 else { break }
                            storage.addAttribute(
                                .font,
                                value: MarkdownEditingStyle.composed(
                                    base: base,
                                    bold: span.role == .bold,
                                    italic: span.role == .italic
                                ),
                                range: run
                            )
                            location = NSMaxRange(run)
                        }
                    default:
                        storage.addAttributes(
                            MarkdownEditingStyle.attributes(
                                for: span.role,
                                revealed: revealed(span)
                            ),
                            range: paint
                        )
                    }
                }
            }
            // ...and the grid is measured last, against what the storage
            // actually resolved to, so a cell with collapsed delimiters still
            // lands on its column. Decorations are recomputed whenever any
            // table was repainted (they are a whole-document set); a limited
            // pass that touched no table leaves them untouched.
            var decorations: [MarkdownInlineImageLayoutManager.Decoration] = []
            if touchedTables || ranges == nil {
                decorations = MarkdownTableStyler.applyGeometry(
                    regions: scan.tables,
                    thematicBreaks: scan.thematicBreaks,
                    to: storage,
                    availableWidth: width
                )
            }
            storage.endEditing()
            isApplyingStyle = false

            if touchedTables || ranges == nil {
                (textView.layoutManager as? MarkdownInlineImageLayoutManager)?
                    .setDecorations(decorations)
                if !decorations.isEmpty || !scan.tables.isEmpty {
                    textView.needsDisplay = true
                }
            }

            // A styling pass must never be able to change the document.
            assert(storage.string == before, "Markdown styling mutated document text")
            if restoringReplacement, let container = textView.textContainer {
                // `restore` asks for a line rect *without* additional layout,
                // which after a whole-document restyle would answer with the
                // unstyled geometry the replacement left behind — and put the
                // reader back at 70 % of where they were. Paid only when a text
                // replacement is waiting for its position; typing never
                // reaches this.
                textView.layoutManager?.ensureLayout(for: container)
            }
            restore(anchor)
        }

        /// The character at the top of the viewport plus how far above the
        /// viewport top its line begins.
        private func viewportAnchor() -> (characterIndex: Int, offset: CGFloat)? {
            guard let textView, let scrollView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer,
                  textView.window != nil else { return nil }
            // Document coordinates. The clip view holds this text view at a
            // large negative frame origin, so its own bounds origin never
            // reaches zero and a `> 0` test against it is false everywhere.
            let visible = scrollView.documentVisibleRect
            guard visible.height > 0, visible.origin.y > 0.5 else { return nil }
            let point = NSPoint(
                x: 0,
                y: visible.origin.y - textView.textContainerOrigin.y
            )
            let glyph = layoutManager.glyphIndex(for: point, in: container)
            let character = layoutManager.characterIndexForGlyph(at: glyph)
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyph,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
            return (character, visible.origin.y - (lineRect.minY + textView.textContainerOrigin.y))
        }

        private func restore(_ anchor: (characterIndex: Int, offset: CGFloat)?) {
            guard let anchor, let textView, let scrollView,
                  let layoutManager = textView.layoutManager else { return }
            let length = (textView.string as NSString).length
            guard anchor.characterIndex < length else { return }
            let glyph = layoutManager.glyphIndexForCharacter(at: anchor.characterIndex)
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyph,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
            let target = lineRect.minY + textView.textContainerOrigin.y + anchor.offset
            let maximum = max(0, textView.bounds.height - scrollView.documentVisibleRect.height)
            let origin = min(max(0, target), maximum)
            guard abs(origin - FilePreviewTextScroll.offset(in: scrollView)) > 0.5 else { return }
            programmaticScrollDepth += 1
            FilePreviewTextScroll.scroll(to: origin, in: textView, scrollView: scrollView)
            programmaticScrollDepth -= 1
        }

        // MARK: Inline images

        private func scheduleImageRefresh() {
            guard let textView else { return }
            // Only re-scan when the set of image lines can actually have moved.
            let source = textView.string
            guard source != appliedImageSource else { return }
            refreshImages(revision: appliedImageRevision ?? 0, force: true)
        }

        func refreshImages(revision: Int, force: Bool) {
            guard let textView, let markdownURL else { return }
            let width = textView.textContainer?.size.width ?? textView.bounds.width
            let source = textView.string
            let unchanged = !force
                && appliedImageRevision == revision
                && appliedImageSource == source
                && appliedImageWidth.map { abs($0 - width) < 0.5 } == true
            guard !unchanged else { return }
            appliedImageRevision = revision
            appliedImageSource = source
            appliedImageWidth = width

            let workspaceRoot = workspaceRoot
            imageTask?.cancel()
            imageTask = Task { [weak self] in
                let lines = await Task.detached(priority: .utility) {
                    MarkdownInlineImages.lines(in: source)
                }.value
                guard !Task.isCancelled else { return }
                var resolved: [(MarkdownInlineImageReference, MarkdownImagePayload?)] = []
                // Decode to the pane's width bucket, not full resolution — a
                // screenshot never needs more pixels than the column shows.
                let displayWidth = self?.textView?.textContainer?.size.width
                for line in lines {
                    for reference in line.references {
                        let payload = await Task.detached(priority: .utility) {
                            MarkdownLocalImageCache.shared.load(
                                source: reference.source,
                                documentURL: markdownURL,
                                workspaceRoot: workspaceRoot,
                                displayWidth: displayWidth
                            )
                        }.value
                        guard !Task.isCancelled else { return }
                        resolved.append((reference, payload))
                    }
                }
                guard !Task.isCancelled, let self, let textView = self.textView,
                      textView.string == source else { return }
                self.install(resolved, availableWidth: width, in: textView)
            }
        }

        private func install(
            _ resolved: [(MarkdownInlineImageReference, MarkdownImagePayload?)],
            availableWidth: CGFloat,
            in textView: MarkdownNativeTextView
        ) {
            guard let layoutManager = textView.layoutManager
                as? MarkdownInlineImageLayoutManager else { return }
            let anchor = viewportAnchor()
            // Several images on one line share the width.
            var perLine: [Int: Int] = [:]
            let nsSource = textView.string as NSString
            for (reference, _) in resolved {
                let line = nsSource.lineRange(for: NSRange(location: reference.range.location, length: 0))
                perLine[line.location, default: 0] += 1
            }
            let placements = resolved.map { reference, payload -> MarkdownInlineImageLayoutManager.Placement in
                let line = nsSource.lineRange(
                    for: NSRange(location: reference.range.location, length: 0)
                )
                let share = CGFloat(max(1, perLine[line.location] ?? 1))
                let budget = max(48, (availableWidth - (share - 1) * 8) / share)
                let size = MarkdownPreviewLayout.imageSize(
                    intrinsicSize: payload?.image.size ?? CGSize(width: 240, height: 44),
                    declaredWidth: reference.declaredWidth,
                    declaredHeight: reference.declaredHeight,
                    availableWidth: budget,
                    // The scroll view magnifies the whole document, so image
                    // sizing works in unzoomed document coordinates.
                    zoom: 1
                )
                return MarkdownInlineImageLayoutManager.Placement(
                    range: reference.range,
                    size: payload == nil ? CGSize(width: min(240, budget), height: 44) : size,
                    image: payload?.image,
                    alt: reference.alt
                )
            }
            layoutManager.setPlacements(placements)
            let fullRange = NSRange(location: 0, length: nsSource.length)
            layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
            if let container = textView.textContainer {
                layoutManager.ensureLayout(for: container)
            }
            restore(anchor)
        }

        /// Give an image line the height of its tallest image.
        ///
        /// The reference text itself is styled away by `MarkdownEditingStyle`,
        /// so the line would otherwise collapse to nothing and the picture
        /// would paint over its neighbours.
        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
            lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
            baselineOffset: UnsafeMutablePointer<CGFloat>,
            in textContainer: NSTextContainer,
            forGlyphRange glyphRange: NSRange
        ) -> Bool {
            guard let manager = layoutManager as? MarkdownInlineImageLayoutManager,
                  !manager.placements.isEmpty,
                  let storage = layoutManager.textStorage else { return false }
            // Deliberately not `characterRange(forGlyphRange:)`: asking the
            // layout manager to map a range mid-layout can re-enter layout.
            let start = manager.characterIndexForGlyph(at: glyphRange.location)
            guard start < storage.length else { return false }
            let line = (storage.string as NSString).lineRange(
                for: NSRange(location: start, length: 0)
            )
            guard let height = manager.imageHeight(inCharacterRange: line) else { return false }
            let target = height + MarkdownInlineImageLayoutManager.verticalPadding
            var rect = lineFragmentRect.pointee
            var used = lineFragmentUsedRect.pointee
            rect.size.height = target
            used.size.height = target
            lineFragmentRect.pointee = rect
            lineFragmentUsedRect.pointee = used
            baselineOffset.pointee = target - 2
            return true
        }

        // MARK: Images from paste, drop, and the menu

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
    }
}

final class MarkdownMagnifyingScrollView: NSScrollView {
    var onMagnificationChanged: ((CGFloat) -> Void)?
    /// A narrower pane means narrower table columns, so the grid re-measures.
    var onDocumentWidthChanged: (() -> Void)?

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
        onDocumentWidthChanged?()
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
    /// Command-click on a Markdown link. A plain click has to keep placing the
    /// caret — this is a document you type in, not a page you browse.
    var onFollowLink: ((Int) -> Void)?

    static func wholeFileSourceEditor() -> MarkdownNativeTextView {
        MarkdownNativeTextView(usingTextLayoutManager: true)
    }

    override func mouseDown(with event: NSEvent) {
        guard onFollowLink != nil, event.modifierFlags.contains(.command) else {
            // A plain click inside a task marker's brackets toggles it; the
            // rest of the line still just places the caret. The toggle rides
            // the normal insertText path, so undo and autosave see one typed
            // character. Only in the rendered surface (onFollowLink set) —
            // the raw source editor renders `[ ]` as plain text with no
            // affordance — and only a truly plain click: Shift extends the
            // selection and must never be swallowed.
            if onFollowLink != nil,
               event.clickCount == 1,
               event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
                let point = convert(event.locationInWindow, from: nil)
                let source = string as NSString
                let index = min(characterIndexForInsertion(at: point), source.length)
                if MarkdownTaskToggle.bracketGroupContains(index, in: source),
                   let edit = MarkdownTaskToggle.toggleRange(at: index, in: source) {
                    insertText(edit.replacement, replacementRange: edit.range)
                    return
                }
            }
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        onFollowLink?(min(characterIndexForInsertion(at: point), (string as NSString).length))
    }

    override func insertTab(_ sender: Any?) {
        if applyListIndent(.indent) { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if applyListIndent(.outdent) { return }
        super.insertBacktab(sender)
    }

    private func applyListIndent(_ direction: MarkdownListIndent.Direction) -> Bool {
        let selection = selectedRange()
        guard selection.length == 0 else { return false }
        let source = string as NSString
        let paragraph = source.paragraphRange(for: selection)
        guard let edit = MarkdownListIndent.edit(
            for: source, paragraph: paragraph, direction: direction
        ) else { return false }
        insertText(edit.replacement, replacementRange: edit.range)
        renumberOrderedBlock(around: paragraph.location)
        return true
    }

    private func renumberOrderedBlock(around location: Int) {
        let source = string as NSString
        guard source.length > 0 else { return }
        let clamped = min(location, source.length - 1)
        guard let block = MarkdownListIndent.orderedBlock(containing: clamped, in: source) else {
            return
        }
        // Renumber at the origin line's (post-edit) depth; nested sub-lists
        // keep their own numbering.
        let originLine = source.substring(
            with: source.paragraphRange(for: NSRange(location: clamped, length: 0))
        )
        let indent = MarkdownListIndent.indent(of: originLine)
        for edit in MarkdownListIndent.renumber(block: block, in: source, indent: indent) {
            insertText(edit.replacement, replacementRange: edit.range)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Every view in the window is asked about key equivalents; only act
        // when this editor actually holds focus, or Cmd+B in a terminal pane
        // would bold-toggle a background document.
        // Caps Lock is part of deviceIndependentFlagsMask; without the
        // subtraction, engaged Caps Lock silently disables all three
        // shortcuts (verified against AppKit).
        if window?.firstResponder === self,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask)
               .subtracting(.capsLock) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "b": formatBold(nil); return true
            case "i": formatItalic(nil); return true
            case "k": formatLink(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
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
        guard imports.isEmpty else {
            onImageImports?(imports, selectedRange())
            return
        }
        // A bare URL pasted over a selection becomes the selection's link
        // destination instead of replacing the words.
        let selection = selectedRange()
        if selection.length > 0,
           let candidate = NSPasteboard.general.string(forType: .string),
           let url = MarkdownInlineFormatting.pastedURL(from: candidate),
           let result = MarkdownInlineFormatting.linkEdit(
               selection: selection, url: url, in: string as NSString
           ) {
            for edit in result.edits {
                insertText(edit.1, replacementRange: edit.0)
            }
            setSelectedRange(result.newSelection)
            return
        }
        super.paste(sender)
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
        toggleWrapOrPlaceholder("**", placeholder: "bold text")
    }

    @objc private func formatItalic(_ sender: Any?) {
        toggleWrapOrPlaceholder("*", placeholder: "italic text")
    }

    /// Cmd+B on an already-bold selection unwraps it; a collapsed selection
    /// falls back to the placeholder insertion the context menu always did.
    private func toggleWrapOrPlaceholder(_ delimiter: String, placeholder: String) {
        let selection = selectedRange()
        if let result = MarkdownInlineFormatting.toggleWrap(
            delimiter, selection: selection, in: string as NSString
        ) {
            for edit in result.edits {
                insertText(edit.1, replacementRange: edit.0)
            }
            setSelectedRange(result.newSelection)
            return
        }
        wrapSelection(prefix: delimiter, suffix: delimiter, placeholder: placeholder)
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
