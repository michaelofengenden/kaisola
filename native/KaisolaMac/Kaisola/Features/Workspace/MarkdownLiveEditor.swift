import AppKit
import Foundation

/// Support for the continuous ("live") Markdown document surface: one text view
/// over the whole file that reads like a document while the bytes underneath
/// stay exact Markdown.
///
/// Everything here is presentation-only. Image placement, scroll retention, and
/// text synchronisation all describe how to *draw* or *scroll* a document; none
/// of them rewrite it. That is the property the block editor was originally
/// built to guarantee, and it is the one this surface has to keep.

// MARK: - Hybrid review diff

/// A bounded, presentation-only line diff for an editable Markdown document.
///
/// The edited source is carried through byte-for-byte. Markers point into that
/// exact UTF-16 string and never own a rewritten copy, so the gutter cannot
/// become another serialization path for tables, code fences, or links.
struct MarkdownHybridDiffPlan: Equatable, Sendable {
    enum MarkerKind: Equatable, Sendable {
        case addition
        case changed
        case deletion
    }

    enum InspectionPresentation: Equatable, Sendable {
        case plainText
    }

    struct Marker: Equatable, Sendable {
        let kind: MarkerKind
        let oldText: String?
        let newText: String?
        /// Content range in the edited source, excluding the line terminator.
        /// A deletion is a zero-length anchor at the nearest surviving line.
        let editedRange: NSRange
        let inspectionText: String
        let inspectionPresentation: InspectionPresentation
        let inspectionAllowsLinkActivation: Bool
    }

    static let maximumComparedLines = AcpDiff.lineDiffCap
    static let maximumMarkers = 500

    let editedSource: String
    let markers: [Marker]
    let isTruncated: Bool

    nonisolated static func build(baseline: String, edited: String) -> Self {
        let oldLines = sourceLines(in: baseline)
        let newLines = sourceLines(in: edited)
        let truncated = oldLines.count > maximumComparedLines
            || newLines.count > maximumComparedLines
        let boundedOld = Array(oldLines.prefix(maximumComparedLines))
        let boundedNew = Array(newLines.prefix(maximumComparedLines))
        let diff = AcpDiff.lines(
            old: boundedOld.map(\.text).joined(separator: "\n"),
            new: boundedNew.map(\.text).joined(separator: "\n")
        )

        var markers: [Marker] = []
        var oldIndex = 0
        var newIndex = 0
        var index = 0

        func append(_ marker: Marker) {
            guard markers.count < maximumMarkers else { return }
            markers.append(marker)
        }

        while index < diff.count, markers.count < maximumMarkers {
            switch diff[index].kind {
            case .context:
                oldIndex += 1
                newIndex += 1
                index += 1
            case .added:
                guard newIndex < boundedNew.count else {
                    index += 1
                    continue
                }
                let line = boundedNew[newIndex]
                append(marker(kind: .addition, old: nil, new: line))
                newIndex += 1
                index += 1
            case .removed:
                var removed: [SourceLine] = []
                while index < diff.count, diff[index].kind == .removed,
                      oldIndex < boundedOld.count {
                    removed.append(boundedOld[oldIndex])
                    oldIndex += 1
                    index += 1
                }
                var added: [SourceLine] = []
                while index < diff.count, diff[index].kind == .added,
                      newIndex < boundedNew.count {
                    added.append(boundedNew[newIndex])
                    newIndex += 1
                    index += 1
                }

                let paired = min(removed.count, added.count)
                for pairIndex in 0..<paired {
                    append(marker(
                        kind: .changed,
                        old: removed[pairIndex],
                        new: added[pairIndex]
                    ))
                }
                for line in removed.dropFirst(paired) {
                    let anchor = newIndex < boundedNew.count
                        ? boundedNew[newIndex].range.location
                        : (edited as NSString).length
                    append(Marker(
                        kind: .deletion,
                        oldText: line.text,
                        newText: nil,
                        editedRange: NSRange(location: anchor, length: 0),
                        inspectionText: line.text,
                        inspectionPresentation: .plainText,
                        inspectionAllowsLinkActivation: false
                    ))
                }
                for line in added.dropFirst(paired) {
                    append(marker(kind: .addition, old: nil, new: line))
                }
            }
        }

        return Self(
            editedSource: edited,
            markers: markers,
            isTruncated: truncated || markers.count == maximumMarkers
        )
    }

    private struct SourceLine: Equatable, Sendable {
        let text: String
        let range: NSRange
    }

    nonisolated private static func sourceLines(in source: String) -> [SourceLine] {
        guard !source.isEmpty else { return [] }
        let nsSource = source as NSString
        var result: [SourceLine] = []
        var location = 0
        while location < nsSource.length {
            let full = nsSource.lineRange(for: NSRange(location: location, length: 0))
            var end = NSMaxRange(full)
            while end > full.location {
                let value = nsSource.character(at: end - 1)
                guard value == 0x0A || value == 0x0D else { break }
                end -= 1
            }
            let range = NSRange(location: full.location, length: end - full.location)
            result.append(SourceLine(text: nsSource.substring(with: range), range: range))
            location = NSMaxRange(full)
        }
        return result
    }

    nonisolated private static func marker(
        kind: MarkerKind,
        old: SourceLine?,
        new: SourceLine?
    ) -> Marker {
        let oldText = old?.text
        let newText = new?.text
        let inspection: String
        switch kind {
        case .addition:
            inspection = newText ?? ""
        case .deletion:
            inspection = oldText ?? ""
        case .changed:
            inspection = "Before:\n\(oldText ?? "")\n\nAfter:\n\(newText ?? "")"
        }
        return Marker(
            kind: kind,
            oldText: oldText,
            newText: newText,
            editedRange: new?.range ?? NSRange(location: 0, length: 0),
            inspectionText: inspection,
            inspectionPresentation: .plainText,
            inspectionAllowsLinkActivation: false
        )
    }
}

/// Clickable vertical ruler for hybrid review. It reads layout geometry from
/// the editor but owns no text, so opening a deleted line cannot accidentally
/// activate a Markdown link or mutate the draft.
@MainActor
final class MarkdownHybridDiffRulerView: NSRulerView {
    private weak var markdownTextView: NSTextView?
    private var diffMarkers: [MarkdownHybridDiffPlan.Marker] = []
    private var markerRects: [NSRect] = []
    private var inspectionPopover: NSPopover?

    init(scrollView: NSScrollView, textView: NSTextView) {
        markdownTextView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 0
        setAccessibilityLabel("Markdown change gutter")
        toolTip = "Click a marker to inspect the exact changed source"
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ markers: [MarkdownHybridDiffPlan.Marker]) {
        diffMarkers = markers
        ruleThickness = markers.isEmpty ? 0 : 14
        scrollView?.tile()
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        super.drawHashMarksAndLabels(in: rect)
        markerRects = diffMarkers.map(markerRect)
        for (marker, markerRect) in zip(diffMarkers, markerRects) {
            color(for: marker.kind).setFill()
            NSBezierPath(roundedRect: markerRect, xRadius: 2, yRadius: 2).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = markerRects.firstIndex(where: {
            $0.insetBy(dx: -2, dy: -4).contains(point)
        }), diffMarkers.indices.contains(index) else {
            super.mouseDown(with: event)
            return
        }
        showInspection(for: diffMarkers[index], relativeTo: markerRects[index])
    }

    private func markerRect(_ marker: MarkdownHybridDiffPlan.Marker) -> NSRect {
        guard let textView = markdownTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              !textView.string.isEmpty else {
            return NSRect(x: 2, y: 4, width: 10, height: 8)
        }
        let stringLength = (textView.string as NSString).length
        let characterIndex = min(max(0, marker.editedRange.location), max(0, stringLength - 1))
        let characterRange = NSRange(
            location: characterIndex,
            length: min(max(marker.editedRange.length, 1), stringLength - characterIndex)
        )
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        var textRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        textRect.origin.x += textView.textContainerOrigin.x
        textRect.origin.y += textView.textContainerOrigin.y
        let local = convert(textRect, from: textView)
        return NSRect(
            x: 2,
            y: local.minY,
            width: 10,
            height: max(4, min(14, local.height))
        )
    }

    private func color(for kind: MarkdownHybridDiffPlan.MarkerKind) -> NSColor {
        switch kind {
        case .addition: .systemGreen
        case .changed: .systemOrange
        case .deletion: .systemRed
        }
    }

    private func showInspection(
        for marker: MarkdownHybridDiffPlan.Marker,
        relativeTo rect: NSRect
    ) {
        inspectionPopover?.close()
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = marker.inspectionText
        textView.setAccessibilityLabel("Changed Markdown source")

        let controller = NSViewController()
        controller.view = scrollView
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 440, height: 180)
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxX)
        inspectionPopover = popover
    }
}

// MARK: - Inline images

/// One image reference the live editor draws in place of its Markdown source.
struct MarkdownInlineImageReference: Equatable, Sendable {
    /// Exact UTF-16 range of the whole reference in the document source.
    let range: NSRange
    let source: String
    let alt: String
    let declaredWidth: Double?
    let declaredHeight: Double?
}

/// A source line made up entirely of image references.
///
/// Only whole-line references are drawn. A line that mixes prose with an image
/// link keeps its literal source visible, because the image would otherwise be
/// painted over the surrounding sentence — the block renderer made the same
/// choice, and matching it keeps rendering predictable.
struct MarkdownInlineImageLine: Equatable, Sendable {
    /// The line's content range, excluding its terminator.
    let lineRange: NSRange
    let references: [MarkdownInlineImageReference]
}

enum MarkdownInlineImages {
    /// Bounded so a pathological document cannot make styling unbounded work.
    static let maximumLines = 512

    private static let markdownPattern =
        #"!\[([^\]\r\n]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"\r\n]*")?\s*\)"#
    private static let htmlPattern = #"(?i)<img\b[^>\r\n]*>"#

    nonisolated static func lines(in source: String) -> [MarkdownInlineImageLine] {
        guard !source.isEmpty else { return [] }
        let nsSource = source as NSString
        guard let markdown = try? NSRegularExpression(pattern: markdownPattern),
              let html = try? NSRegularExpression(pattern: htmlPattern) else { return [] }

        var result: [MarkdownInlineImageLine] = []
        var location = 0
        while location < nsSource.length, result.count < maximumLines {
            let full = nsSource.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(full)
            let contentRange = contentRange(of: full, in: nsSource)
            guard contentRange.length > 0 else { continue }
            let line = nsSource.substring(with: contentRange)
            // A cheap reject keeps the regexes off the overwhelming majority of
            // lines in a long document.
            guard line.contains("![")
                || line.range(of: "<img", options: .caseInsensitive) != nil else { continue }
            appendIfWholeLine(
                line: line,
                contentRange: contentRange,
                markdown: markdown,
                html: html,
                into: &result
            )
        }
        return result
    }

    private static func appendIfWholeLine(
        line: String,
        contentRange: NSRange,
        markdown: NSRegularExpression,
        html: NSRegularExpression,
        into result: inout [MarkdownInlineImageLine]
    ) {
        let nsLine = line as NSString
        let lineRange = NSRange(location: 0, length: nsLine.length)
        var references: [MarkdownInlineImageReference] = []
        var covered: [NSRange] = []

        for match in markdown.matches(in: line, range: lineRange) {
            let alt = substring(nsLine, match.range(at: 1))
            let source = substring(nsLine, match.range(at: 2))
            guard !source.isEmpty else { continue }
            covered.append(match.range)
            references.append(
                MarkdownInlineImageReference(
                    range: offset(match.range, by: contentRange.location),
                    source: source,
                    alt: alt,
                    declaredWidth: nil,
                    declaredHeight: nil
                )
            )
        }
        for match in html.matches(in: line, range: lineRange) {
            let tag = nsLine.substring(with: match.range)
            guard let source = attribute("src", in: tag), !source.isEmpty else { continue }
            covered.append(match.range)
            references.append(
                MarkdownInlineImageReference(
                    range: offset(match.range, by: contentRange.location),
                    source: source,
                    alt: attribute("alt", in: tag) ?? "",
                    declaredWidth: numericAttribute("width", in: tag),
                    declaredHeight: numericAttribute("height", in: tag)
                )
            )
        }

        guard !references.isEmpty else { return }
        // Everything outside the references has to be whitespace, otherwise the
        // line carries prose that must stay readable.
        let remainder = NSMutableString(string: line)
        for range in covered.sorted(by: { $0.location > $1.location }) {
            remainder.replaceCharacters(in: range, with: "")
        }
        guard (remainder as String).trimmingCharacters(in: .whitespaces).isEmpty else { return }

        result.append(
            MarkdownInlineImageLine(
                lineRange: contentRange,
                references: references.sorted { $0.range.location < $1.range.location }
            )
        )
    }

    private static func contentRange(of full: NSRange, in source: NSString) -> NSRange {
        var end = NSMaxRange(full)
        while end > full.location {
            let value = source.character(at: end - 1)
            guard value == 0x0A || value == 0x0D else { break }
            end -= 1
        }
        return NSRange(location: full.location, length: end - full.location)
    }

    private static func offset(_ range: NSRange, by delta: Int) -> NSRange {
        NSRange(location: range.location + delta, length: range.length)
    }

    private static func substring(_ source: NSString, _ range: NSRange) -> String {
        guard range.location != NSNotFound, NSMaxRange(range) <= source.length else { return "" }
        return source.substring(with: range)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "(?i)\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: tag,
                range: NSRange(location: 0, length: (tag as NSString).length)
              ) else { return nil }
        return substring(tag as NSString, match.range(at: 1))
    }

    private static func numericAttribute(_ name: String, in tag: String) -> Double? {
        guard let raw = attribute(name, in: tag) else { return nil }
        return Double(raw.trimmingCharacters(in: CharacterSet(charactersIn: "px ")))
    }
}

// MARK: - Text synchronisation

/// Decides what a SwiftUI update owes the live text view.
///
/// The whole point is the `unchanged` case. Saving, autosaving, journaling, and
/// external-change reconciliation of identical bytes all re-run the SwiftUI
/// body with a string equal to the one already on screen. Replacing the text
/// storage in that situation collapses the layout and throws the viewport back
/// to the top of the document — which is precisely the jump this surface exists
/// to remove.
enum MarkdownEditorTextSync {
    enum Plan: Equatable {
        /// The view already holds these bytes; touch nothing.
        case unchanged
        /// Replace the storage and restore this clamped selection.
        case replace(selection: NSRange)
    }

    static func plan(current: String, incoming: String, selection: NSRange) -> Plan {
        guard current != incoming else { return .unchanged }
        let length = (incoming as NSString).length
        let location = min(max(0, selection.location), length)
        let remaining = length - location
        let selectionLength = min(max(0, selection.length), max(0, remaining))
        return .replace(selection: NSRange(location: location, length: selectionLength))
    }
}

/// Keeps the viewport pinned across a text replacement that changed the
/// document's height (an external reload, a zoom step, a font change).
enum MarkdownEditorScrollRetention {
    /// The clip origin to restore.
    ///
    /// A document whose height barely moved keeps its exact pixel offset, so
    /// ordinary editing never drifts. A document that grew or shrank materially
    /// keeps its *proportional* position instead, because the old pixel offset
    /// no longer refers to the same text.
    static func restoredOrigin(
        previousOrigin: CGFloat,
        previousContentHeight: CGFloat,
        newContentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        let newScrollable = max(0, newContentHeight - viewportHeight)
        guard newScrollable > 0 else { return 0 }
        let previousScrollable = max(0, previousContentHeight - viewportHeight)
        guard previousScrollable > 0 else { return 0 }
        let drift = abs(newContentHeight - previousContentHeight)
        guard drift > max(1, previousContentHeight * 0.02) else {
            return min(previousOrigin, newScrollable)
        }
        let fraction = min(1, max(0, previousOrigin / previousScrollable))
        return min(newScrollable, fraction * newScrollable)
    }

    /// Whether the character that was at the top of the viewport still exists
    /// in the incoming text.
    ///
    /// A pixel or proportional restore is measured against the *unstyled*
    /// height of a freshly replaced string — headings at body size, table rows
    /// uncollapsed — so it lands thousands of points away on a long document.
    /// Restoring the same character instead is only meaningful while that
    /// character is still there, which is exactly the case that matters:
    /// reconciling an external edit of the file already open.
    static func anchorSurvives(characterIndex: Int, in text: String) -> Bool {
        characterIndex >= 0 && characterIndex < (text as NSString).length
    }
}

// MARK: - Inline image layout

/// Draws whole-line Markdown images in place of their source text.
///
/// The images are painted by the layout manager and their line fragments are
/// inflated through the layout-manager delegate. Nothing is inserted into the
/// text storage: an `NSTextAttachment` would need a real `U+FFFC` character in
/// the document, which is exactly the kind of round-trip rewriting that once
/// deleted relative images from saved files.
/// Not actor-isolated: AppKit calls layout and drawing hooks on the main thread
/// but declares them without annotations, and an isolated override cannot
/// satisfy them. Every mutation goes through `setPlacements` from the editor's
/// main-actor coordinator.
final class MarkdownInlineImageLayoutManager: NSLayoutManager {
    struct Placement {
        let range: NSRange
        let size: CGSize
        let image: NSImage?
        let alt: String
    }

    /// Chrome drawn behind a whole line: the header band of a table, or the
    /// hairline that a `|---|` delimiter row and a `---` break render as.
    ///
    /// Anchored to a character index rather than a rectangle, so it follows the
    /// line it belongs to through reflow, zoom, and every edit above it — and
    /// so the delimiter row can *look* like a rule while its dashes stay in the
    /// document exactly as typed.
    struct Decoration: Equatable {
        enum Kind: Equatable {
            case rule
            case fill
        }

        let characterIndex: Int
        let width: CGFloat
        let kind: Kind
    }

    /// Vertical breathing room drawn around an image line.
    static let verticalPadding: CGFloat = 10

    private(set) var placements: [Placement] = []
    private(set) var decorations: [Decoration] = []
    private var placementsByLocation: [Int: Placement] = [:]

    func setPlacements(_ placements: [Placement]) {
        self.placements = placements
        placementsByLocation = Dictionary(
            placements.map { ($0.range.location, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func setDecorations(_ decorations: [Decoration]) {
        self.decorations = decorations
    }

    /// The tallest image whose reference starts inside `characterRange`.
    func imageHeight(inCharacterRange characterRange: NSRange) -> CGFloat? {
        var height: CGFloat?
        for placement in placements where NSLocationInRange(placement.range.location, characterRange) {
            height = max(height ?? 0, placement.size.height)
        }
        return height
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // Fills go under everything, including the selection highlight and any
        // `.backgroundColor` run `super` paints, so a selected table header
        // still reads as selected.
        drawDecorations(.fill, forGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        drawDecorations(.rule, forGlyphRange: glyphsToShow, at: origin)
        guard !placements.isEmpty else { return }
        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        var drawnLines: Set<Int> = []
        for placement in placements
        where NSLocationInRange(placement.range.location, characterRange) {
            let glyphIndex = self.glyphIndexForCharacter(at: placement.range.location)
            guard glyphIndex < numberOfGlyphs else { continue }
            var lineRange = NSRange(location: 0, length: 0)
            let fragment = lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineRange,
                withoutAdditionalLayout: true
            )
            // Several images can share one line (a badge row). Lay them out
            // left to right from the fragment origin, once per line.
            guard drawnLines.insert(lineRange.location).inserted else { continue }
            let lineCharacters = self.characterRange(forGlyphRange: lineRange, actualGlyphRange: nil)
            var x = fragment.minX + origin.x
            for candidate in placements
            where NSLocationInRange(candidate.range.location, lineCharacters) {
                let rect = NSRect(
                    x: x,
                    y: fragment.minY + origin.y + Self.verticalPadding / 2,
                    width: candidate.size.width,
                    height: candidate.size.height
                )
                draw(candidate, in: rect)
                x += candidate.size.width + 8
            }
        }
    }

    private func drawDecorations(
        _ kind: Decoration.Kind,
        forGlyphRange glyphsToShow: NSRange,
        at origin: NSPoint
    ) {
        guard decorations.contains(where: { $0.kind == kind }) else { return }
        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for decoration in decorations
        where decoration.kind == kind
            && NSLocationInRange(decoration.characterIndex, characterRange) {
            let glyphIndex = self.glyphIndexForCharacter(at: decoration.characterIndex)
            guard glyphIndex < numberOfGlyphs else { continue }
            let fragment = lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
            let x = fragment.minX + origin.x
            switch kind {
            case .fill:
                MarkdownTableStyle.headerFill.setFill()
                NSRect(
                    x: x,
                    y: fragment.minY + origin.y,
                    width: decoration.width,
                    height: fragment.height
                ).fill()
            case .rule:
                MarkdownTableStyle.ruleColor.setFill()
                NSRect(
                    x: x,
                    y: (fragment.midY + origin.y - MarkdownTableStyle.ruleThickness / 2).rounded(),
                    width: decoration.width,
                    height: MarkdownTableStyle.ruleThickness
                ).fill()
            }
        }
    }

    private func draw(_ placement: Placement, in rect: NSRect) {
        guard let image = placement.image else {
            drawPlaceholder(for: placement, in: rect)
            return
        }
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        image.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawPlaceholder(for placement: Placement, in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.quaternaryLabelColor.setFill()
        path.fill()
        let label = placement.alt.isEmpty ? "Image unavailable" : placement.alt
        // Placeholder copy, so it takes the secondary ink rather than a lighter
        // rung — and the *glass* weight of it, because the plate under this
        // label is the quaternary fill above rather than the document's white.
        // On that ground α 0.55 measures 4.50:1 and α 0.60 measures 5.36:1.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: KaisolaInk.nsColor(.secondary),
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}
