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
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}
