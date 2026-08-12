import AppKit
import Foundation
import SwiftUI

extension Notification.Name {
    static var kaisolaTranscriptFindCommand: Notification.Name {
        Notification.Name("kaisola.transcriptFindCommand")
    }
}

enum AcpTranscriptFindCommand: Int, Equatable {
    static let notificationActionKey = "action"

    case show = 1
    case next = 2
    case previous = 3
    case useSelection = 7
}

enum AcpTranscriptSearchDirection: Equatable {
    case next
    case previous
}

struct AcpTranscriptSearchMatch: Equatable, Sendable {
    let rowID: String
    let occurrence: Int
}

/// Builds a bounded index over exactly the transcript content the chat can
/// render. The durable store remains complete; this view-local index never
/// retains unbounded tool output or scans unloaded pages until asked.
enum AcpTranscriptSearchIndex {
    static let maximumMatches = 500
    static let maximumSearchCharacters = 512_000
    static let maximumQueryCharacters = 512

    struct Result: Equatable, Sendable {
        let matches: [AcpTranscriptSearchMatch]
        let hasAdditionalMatches: Bool
    }

    static func build(query: String, rows: [AcpTranscriptRow]) -> Result {
        let query = String(query.prefix(maximumQueryCharacters))
        guard !query.isEmpty else { return Result(matches: [], hasAdditionalMatches: false) }

        var matches: [AcpTranscriptSearchMatch] = []
        var remainingCharacters = maximumSearchCharacters
        var hasAdditionalMatches = false
        for (rowIndex, row) in rows.enumerated() where remainingCharacters > 0 {
            let source = searchableText(for: row)
            let bounded = String(source.prefix(remainingCharacters))
            remainingCharacters -= bounded.count
            var occurrence = 0
            var cursor = bounded.startIndex
            while cursor < bounded.endIndex,
                  let range = bounded.range(
                      of: query,
                      options: [.caseInsensitive, .diacriticInsensitive],
                      range: cursor..<bounded.endIndex
                  ) {
                if matches.count == maximumMatches {
                    hasAdditionalMatches = true
                    return Result(matches: matches, hasAdditionalMatches: true)
                }
                matches.append(AcpTranscriptSearchMatch(rowID: row.id, occurrence: occurrence))
                occurrence += 1
                cursor = range.upperBound
            }
            if bounded.count < source.count || (remainingCharacters == 0 && rowIndex < rows.count - 1) {
                hasAdditionalMatches = true
            }
        }
        return Result(matches: matches, hasAdditionalMatches: hasAdditionalMatches)
    }

    private static func searchableText(for row: AcpTranscriptRow) -> String {
        switch row {
        case let .user(_, text, _),
             let .message(_, text),
             let .thought(_, text),
             let .permissionDecision(_, text):
            return AcpChatRendering.bounded(
                text,
                characterLimit: AcpChatRendering.assistantCharacterLimit,
                lineLimit: AcpChatRendering.assistantLineLimit
            ).text
        case let .tool(call):
            var fields = [call.title, call.kind, call.status.rawValue]
            fields.append(contentsOf: call.declaredFilePaths)
            for artifact in call.content {
                switch artifact {
                case let .text(text):
                    fields.append(AcpChatRendering.bounded(
                        text,
                        characterLimit: AcpChatRendering.toolCharacterLimit,
                        lineLimit: AcpChatRendering.toolLineLimit
                    ).text)
                case let .diff(path, oldText, newText):
                    fields.append(path)
                    if let oldText {
                        fields.append(AcpChatRendering.bounded(
                            oldText,
                            characterLimit: AcpChatRendering.diffCharacterLimit,
                            lineLimit: AcpChatRendering.diffLineLimit
                        ).text)
                    }
                    fields.append(AcpChatRendering.bounded(
                        newText,
                        characterLimit: AcpChatRendering.diffCharacterLimit,
                        lineLimit: AcpChatRendering.diffLineLimit
                    ).text)
                case let .terminal(id):
                    fields.append(id)
                }
            }
            return fields.joined(separator: "\n")
        case let .plan(_, entries):
            return entries.flatMap { [$0.content, $0.priority, $0.status] }.joined(separator: "\n")
        case let .runProfileAudit(_, profile):
            return [profile.name, profile.modelID]
                .compactMap { $0 }
                .joined(separator: "\n")
        }
    }
}

struct AcpTranscriptSearchState: Equatable, Sendable {
    private(set) var isPresented = false
    private(set) var query = ""
    private(set) var matches: [AcpTranscriptSearchMatch] = []
    private(set) var hasAdditionalMatches = false
    private var selectedIndex: Int?

    var matchCount: Int { matches.count }
    var currentRowID: String? {
        guard let selectedIndex, matches.indices.contains(selectedIndex) else { return nil }
        return matches[selectedIndex].rowID
    }

    mutating func present() { isPresented = true }

    mutating func dismiss() {
        isPresented = false
        selectedIndex = nil
    }

    mutating func updateQuery(_ value: String, rows: [AcpTranscriptRow]) {
        query = String(value.prefix(AcpTranscriptSearchIndex.maximumQueryCharacters))
        selectedIndex = nil
        rebuild(rows: rows, preserving: nil)
    }

    mutating func refresh(rows: [AcpTranscriptRow]) {
        let selected = selectedIndex.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        rebuild(rows: rows, preserving: selected)
    }

    mutating func move(_ direction: AcpTranscriptSearchDirection) -> String? {
        guard !matches.isEmpty else {
            selectedIndex = nil
            return nil
        }
        switch (direction, selectedIndex) {
        case (.next, nil): selectedIndex = 0
        case (.previous, nil): selectedIndex = matches.count - 1
        case let (.next, index?): selectedIndex = (index + 1) % matches.count
        case let (.previous, index?): selectedIndex = (index - 1 + matches.count) % matches.count
        }
        return currentRowID
    }

    func statusText(hasHiddenEarlierRows: Bool) -> String {
        guard !query.isEmpty else { return "Type to search" }
        guard !matches.isEmpty else {
            return hasHiddenEarlierRows ? "No matches loaded" : "No matches"
        }
        if let selectedIndex {
            return "\(selectedIndex + 1) of \(matches.count)"
        }
        if hasAdditionalMatches { return "\(matches.count)+ matches" }
        return "\(matches.count) \(matches.count == 1 ? "match" : "matches")"
    }

    private mutating func rebuild(
        rows: [AcpTranscriptRow],
        preserving selected: AcpTranscriptSearchMatch?
    ) {
        let result = AcpTranscriptSearchIndex.build(query: query, rows: rows)
        matches = result.matches
        hasAdditionalMatches = result.hasAdditionalMatches
        selectedIndex = selected.flatMap { matches.firstIndex(of: $0) }
    }
}

struct AcpTranscriptSearchNavigationRequest: Equatable {
    let generation: UInt64
    let direction: AcpTranscriptSearchDirection
}

/// Captures the actual row mounted at the top of the AppKit scroll viewport,
/// including a partially clipped row's sub-point offset, then restores that
/// same reading position after older transcript rows are prepended.
///
/// A data-window anchor such as `visibleRows.first` is not a viewport anchor:
/// it can sit hundreds of points above what the reader is looking at. Marker
/// views bridge the laid-out SwiftUI rows to the owning `NSScrollView`, so the
/// restore is based on document geometry rather than row addressability.
@MainActor
final class AcpTranscriptViewportAnchor: ObservableObject {
    struct Snapshot: Equatable {
        let rowID: String
        let offsetFromViewportTop: CGFloat
    }

    struct Restoration: Equatable {
        let rowID: String
        let requestedOffset: CGFloat
        let restoredOffset: CGFloat

        var error: CGFloat { abs(restoredOffset - requestedOffset) }
    }

    final class MarkerView: NSView {
        weak var owner: AcpTranscriptViewportAnchor?
        var rowID = ""

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            owner?.register(self)
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            // LazyVStack may temporarily reparent a representable without
            // recreating or updating it. Re-register the same weak marker when
            // it rejoins the mounted hierarchy; otherwise a later prepend can
            // have visible AX rows but no addressable AppKit anchor.
            if superview != nil { owner?.register(self) }
        }

        override func viewWillMove(toSuperview newSuperview: NSView?) {
            if newSuperview == nil { owner?.unregister(self) }
            super.viewWillMove(toSuperview: newSuperview)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class WeakMarker {
        weak var value: MarkerView?
        init(_ value: MarkerView) { self.value = value }
    }

    @MainActor
    private final class CapturedViewport {
        let rowID: String
        weak var scrollView: NSScrollView?
        let documentBounds: NSRect
        let viewport: NSRect
        let documentWasFlipped: Bool

        init(rowID: String, geometry: Geometry) {
            self.rowID = rowID
            scrollView = geometry.scrollView
            documentBounds = geometry.documentView.bounds
            viewport = geometry.viewport
            documentWasFlipped = geometry.documentView.isFlipped
        }
    }

    @MainActor
    private struct Geometry {
        let marker: MarkerView
        let scrollView: NSScrollView
        let documentView: NSView
        let rowRect: NSRect
        let viewport: NSRect

        var offsetFromViewportTop: CGFloat {
            documentView.isFlipped
                ? rowRect.minY - viewport.minY
                : viewport.maxY - rowRect.maxY
        }
    }

    private var markers: [String: WeakMarker] = [:]
    private var capturedViewport: CapturedViewport?

    fileprivate func register(_ marker: MarkerView) {
        guard !marker.rowID.isEmpty else { return }
        markers[marker.rowID] = WeakMarker(marker)
    }

    fileprivate func unregister(_ marker: MarkerView) {
        guard markers[marker.rowID]?.value === marker else { return }
        markers.removeValue(forKey: marker.rowID)
    }

    /// The uppermost row intersecting the real clip view. LazyVStack may keep
    /// nearby rows mounted as prefetch, so mounted alone is insufficient.
    func capture() -> Snapshot? {
        purgeReleasedMarkers()
        let candidate = markers.compactMap { rowID, marker -> (Snapshot, Geometry)? in
            guard let view = marker.value,
                  let geometry = geometry(for: view),
                  geometry.rowRect.intersects(geometry.viewport) else { return nil }
            return (
                Snapshot(
                    rowID: rowID,
                    offsetFromViewportTop: geometry.offsetFromViewportTop
                ),
                geometry
            )
        }
        .min { lhs, rhs in
            lhs.0.offsetFromViewportTop < rhs.0.offsetFromViewportTop
        }
        guard let candidate else { return nil }
        capturedViewport = CapturedViewport(rowID: candidate.0.rowID, geometry: candidate.1)
        return candidate.0
    }

    /// Repositions the AppKit clip view to the exact captured intra-row offset.
    /// The caller may first use `ScrollViewProxy.scrollTo` when LazyVStack has
    /// unmounted the captured row; once its marker remounts this method applies
    /// the precise correction that a SwiftUI anchor cannot represent.
    @discardableResult
    func restore(_ snapshot: Snapshot) -> Restoration? {
        purgeReleasedMarkers()
        guard let marker = markers[snapshot.rowID]?.value,
              let initialGeometry = geometry(for: marker) else {
            // A large prepend can make LazyVStack evict the captured marker
            // before its exact row restoration runs. Preserve the underlying
            // clip position from the measured document growth so SwiftUI
            // remounts the same row, then let the caller retry and validate
            // the real marker offset rather than manufacturing a PASS.
            _ = restoreCapturedViewportGeometry(snapshot)
            return nil
        }

        let clipView = initialGeometry.scrollView.contentView
        var targetBounds = clipView.bounds
        if initialGeometry.documentView.isFlipped {
            targetBounds.origin.y = initialGeometry.rowRect.minY - snapshot.offsetFromViewportTop
        } else {
            targetBounds.origin.y = initialGeometry.rowRect.maxY
                + snapshot.offsetFromViewportTop
                - targetBounds.height
        }
        targetBounds = clipView.constrainBoundsRect(targetBounds)
        clipView.scroll(to: targetBounds.origin)
        initialGeometry.scrollView.reflectScrolledClipView(clipView)
        initialGeometry.scrollView.layoutSubtreeIfNeeded()

        guard let restored = geometry(for: marker) else { return nil }
        return Restoration(
            rowID: snapshot.rowID,
            requestedOffset: snapshot.offsetFromViewportTop,
            restoredOffset: restored.offsetFromViewportTop
        )
    }

    private func geometry(for marker: MarkerView) -> Geometry? {
        guard marker.window != nil,
              let scrollView = marker.enclosingScrollView,
              let documentView = scrollView.documentView else { return nil }
        scrollView.layoutSubtreeIfNeeded()
        return Geometry(
            marker: marker,
            scrollView: scrollView,
            documentView: documentView,
            rowRect: marker.convert(marker.bounds, to: documentView),
            viewport: scrollView.documentVisibleRect
        )
    }

    @discardableResult
    private func restoreCapturedViewportGeometry(_ snapshot: Snapshot) -> Bool {
        guard let capturedViewport,
              capturedViewport.rowID == snapshot.rowID,
              let scrollView = capturedViewport.scrollView,
              let documentView = scrollView.documentView,
              documentView.window != nil,
              documentView.isFlipped == capturedViewport.documentWasFlipped else { return false }
        scrollView.layoutSubtreeIfNeeded()
        documentView.layoutSubtreeIfNeeded()
        guard documentView.bounds.height + 0.5 >= capturedViewport.documentBounds.height else {
            return false
        }

        let clipView = scrollView.contentView
        var targetBounds = clipView.bounds
        if documentView.isFlipped {
            let trailingDistance = capturedViewport.documentBounds.maxY
                - capturedViewport.viewport.maxY
            targetBounds.origin.y = documentView.bounds.maxY
                - trailingDistance
                - targetBounds.height
        } else {
            // AppKit's non-flipped document coordinates grow upward. Content
            // prepended at the visual top does not move the existing row's Y.
            targetBounds.origin.y = capturedViewport.viewport.minY
        }
        targetBounds = clipView.constrainBoundsRect(targetBounds)
        clipView.scroll(to: targetBounds.origin)
        scrollView.reflectScrolledClipView(clipView)
        scrollView.layoutSubtreeIfNeeded()
        return true
    }

    private func purgeReleasedMarkers() {
        markers = markers.filter { $0.value.value != nil }
    }
}

/// Zero-hit-area AppKit marker mounted behind one rendered transcript row.
/// It deliberately exposes no accessibility element of its own; the row keeps
/// its existing combined label and stable `acp.transcript.*` identifier.
@MainActor
struct AcpTranscriptViewportMarker: NSViewRepresentable {
    let rowID: String
    let anchor: AcpTranscriptViewportAnchor

    func makeNSView(context: Context) -> AcpTranscriptViewportAnchor.MarkerView {
        let view = AcpTranscriptViewportAnchor.MarkerView()
        view.setAccessibilityElement(false)
        update(view)
        return view
    }

    func updateNSView(
        _ nsView: AcpTranscriptViewportAnchor.MarkerView,
        context: Context
    ) {
        update(nsView)
    }

    static func dismantleNSView(
        _ nsView: AcpTranscriptViewportAnchor.MarkerView,
        coordinator: Void
    ) {
        nsView.owner?.unregister(nsView)
    }

    private func update(_ view: AcpTranscriptViewportAnchor.MarkerView) {
        if view.owner !== anchor || view.rowID != rowID {
            view.owner?.unregister(view)
            view.owner = anchor
            view.rowID = rowID
        }
        anchor.register(view)
    }
}

/// Incremental structural cache for one assistant row. ACP message chunks are
/// append-only, so an update reparses the final (potentially still-open) block
/// rather than every stable block above it. Two short sentinels validate that
/// contract without an O(n) `hasPrefix` scan on every token; a replacement,
/// shrink, or changed sentinel falls back to a complete parse.
final class AcpTranscriptBlockCache {
    private static let sentinelLength = 256

    private var lastSource = ""
    private var lastUTF16Length = 0
    private var prefixSentinel = ""
    private var tailSentinel = ""
    private var cachedBlocks: [MarkdownSourceBlock] = []

    private(set) var parseCount = 0
    private(set) var lastParsedUTF16Count = 0
    private(set) var totalParsedUTF16Count = 0

    func blocks(for source: String) -> [MarkdownSourceBlock] {
        let nsSource = source as NSString
        let length = nsSource.length
        if length == lastUTF16Length, source == lastSource { return cachedBlocks }

        let blocks: [MarkdownSourceBlock]
        let parsedLength: Int
        if isValidatedAppend(nsSource), let tail = cachedBlocks.last {
            let restart = tail.range.location
            let suffixRange = NSRange(location: restart, length: length - restart)
            let suffix = nsSource.substring(with: suffixRange)
            let reparsed = MarkdownSourceDocument.blocks(in: suffix).map { block in
                MarkdownSourceBlock(
                    range: NSRange(
                        location: block.range.location + restart,
                        length: block.range.length
                    ),
                    source: block.source,
                    block: block.block
                )
            }
            blocks = Array(cachedBlocks.dropLast()) + reparsed
            parsedLength = suffixRange.length
        } else if isValidatedAppend(nsSource), cachedBlocks.isEmpty {
            let suffixRange = NSRange(
                location: lastUTF16Length,
                length: length - lastUTF16Length
            )
            let suffix = nsSource.substring(with: suffixRange)
            let reparsed = MarkdownSourceDocument.blocks(in: suffix).map { block in
                MarkdownSourceBlock(
                    range: NSRange(
                        location: block.range.location + lastUTF16Length,
                        length: block.range.length
                    ),
                    source: block.source,
                    block: block.block
                )
            }
            blocks = reparsed
            parsedLength = suffixRange.length
        } else {
            blocks = MarkdownSourceDocument.blocks(in: source)
            parsedLength = length
        }

        cachedBlocks = blocks
        lastSource = source
        lastUTF16Length = length
        prefixSentinel = nsSource.substring(with: NSRange(
            location: 0,
            length: min(Self.sentinelLength, length)
        ))
        let tailLength = min(Self.sentinelLength, length)
        tailSentinel = nsSource.substring(with: NSRange(
            location: length - tailLength,
            length: tailLength
        ))
        parseCount += 1
        lastParsedUTF16Count = parsedLength
        totalParsedUTF16Count += parsedLength
        return cachedBlocks
    }

    private func isValidatedAppend(_ source: NSString) -> Bool {
        guard lastUTF16Length > 0, source.length > lastUTF16Length else { return false }
        let prefixLength = (prefixSentinel as NSString).length
        guard source.substring(with: NSRange(location: 0, length: prefixLength)) == prefixSentinel else {
            return false
        }
        let tailLength = (tailSentinel as NSString).length
        return source.substring(with: NSRange(
            location: lastUTF16Length - tailLength,
            length: tailLength
        )) == tailSentinel
    }
}

private actor AcpTranscriptBlockRenderer {
    private let cache = AcpTranscriptBlockCache()

    func blocks(for source: String) -> [MarkdownSourceBlock] {
        cache.blocks(for: source)
    }
}

/// Coalesces rapid token delivery to one off-main structural pass per display
/// cadence. The newest source is never dropped: if more text arrives during a
/// parse, the worker immediately schedules the latest snapshot next.
@MainActor
private final class AcpTranscriptRenderModel: ObservableObject {
    @Published private(set) var blocks: [MarkdownSourceBlock] = []

    private let renderer = AcpTranscriptBlockRenderer()
    private var pendingSource: String?
    private var worker: Task<Void, Never>?

    func submit(_ source: String) {
        pendingSource = source
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(45))
                guard !Task.isCancelled, let self, let source = self.pendingSource else {
                    self?.worker = nil
                    return
                }
                self.pendingSource = nil
                let rendered = await self.renderer.blocks(for: source)
                guard !Task.isCancelled else { return }
                self.blocks = rendered
                if self.pendingSource == nil {
                    self.worker = nil
                    return
                }
            }
        }
    }

    deinit { worker?.cancel() }
}

struct AcpTranscriptFileReference: Equatable, Sendable {
    let range: NSRange
    let fileURL: URL
    let line: Int?

    var linkURL: URL {
        guard let line,
              var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) else {
            return fileURL
        }
        components.fragment = "L\(line)"
        return components.url ?? fileURL
    }
}

enum AcpTranscriptInlineRendering {
    private static let pathExpression = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])((?:\.{0,2}/|~/|/)?(?:[A-Za-z0-9_@+.-]+/)*[A-Za-z0-9_@+-]+\.[A-Za-z0-9_+-]{1,16}(?::[1-9][0-9]*(?::[1-9][0-9]*)?)?)"#
    )

    static func attributed(_ markdown: String, workspaceURL: URL?) -> AttributedString {
        var result = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
        guard let workspaceURL else { return result }
        let plain = String(result.characters)
        let references = fileReferences(in: plain, workspaceURL: workspaceURL)
        guard !references.isEmpty else { return result }

        for reference in references {
            guard let stringRange = Range(reference.range, in: plain) else { continue }
            let lowerOffset = plain.distance(from: plain.startIndex, to: stringRange.lowerBound)
            let upperOffset = plain.distance(from: plain.startIndex, to: stringRange.upperBound)
            let lower = result.characters.index(result.characters.startIndex, offsetBy: lowerOffset)
            let upper = result.characters.index(result.characters.startIndex, offsetBy: upperOffset)
            guard lower < upper else { continue }
            let range = lower..<upper
            // An authored Markdown link owns its destination. Bare citations
            // receive local links only when no link attribute already exists.
            guard !result[range].runs.contains(where: { $0.link != nil }) else { continue }
            result[range].link = reference.linkURL
            result[range].underlineStyle = .single
        }
        return result
    }

    static func fileReferences(in text: String, workspaceURL: URL) -> [AcpTranscriptFileReference] {
        guard let pathExpression else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return pathExpression.matches(in: text, range: fullRange).compactMap { match in
            guard match.numberOfRanges > 1,
                  let candidateRange = Range(match.range(at: 1), in: text) else { return nil }
            let candidate = String(text[candidateRange])
            guard case let .file(fileURL, line)? = NativeTerminalSurface.Coordinator.linkTarget(
                for: candidate,
                workingDirectory: workspaceURL
            ),
            WorkspacePreviewLinkPolicy.isContained(fileURL, in: workspaceURL),
            FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return AcpTranscriptFileReference(
                range: match.range(at: 1),
                fileURL: fileURL,
                line: line
            )
        }
    }
}

enum AcpTranscriptLinkRouting {
    @MainActor
    static func open(_ link: URL, workspaceURL: URL?) -> OpenURLAction.Result {
        guard let workspaceURL else { return .discarded }
        let documentURL = workspaceURL.appendingPathComponent(".kaisola-transcript.md")
        switch WorkspacePreviewLinkPolicy.decision(
            for: link,
            documentURL: documentURL,
            workspaceRoot: workspaceURL
        ) {
        case let .external(url):
            NSWorkspace.shared.open(url)
            return .handled
        case let .workspaceFile(url, line):
            var userInfo: [AnyHashable: Any] = [
                "url": url,
                "workspaceHint": workspaceURL,
            ]
            if let line { userInfo["line"] = line }
            NotificationCenter.default.post(
                name: .kaisolaOpenFileLink,
                object: nil,
                userInfo: userInfo
            )
            return .handled
        case .blocked:
            ToastCenter.shared.show(
                "Kaisola blocked an unsafe or out-of-project transcript link.",
                style: .info
            )
            return .discarded
        }
    }
}

enum AcpTranscriptCodeLanguage {
    static func grammar(for fence: String?) -> SyntaxHighlighter.GrammarChoice? {
        guard let token = fence?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .first else { return nil }
        switch token {
        case "swift": return .shipped(.swift)
        case "js", "jsx", "javascript", "ts", "tsx", "typescript": return .shipped(.javascript)
        case "py", "python": return .shipped(.python)
        case "json", "jsonc", "json5": return .shipped(.json)
        case "sh", "shell", "bash", "zsh", "console": return .shipped(.shell)
        case "yml", "yaml": return .shipped(.yaml)
        case "html", "xml", "svg": return .shipped(.html)
        case "css", "scss", "less": return .shipped(.css)
        default: return SyntaxHighlighter.grammar(forFence: String(token))
        }
    }
}

struct AssistantMarkdownText: View {
    let text: String
    let workspaceURL: URL?
    @StateObject private var renderer = AcpTranscriptRenderModel()
    @State private var characterLimit = AcpChatRendering.assistantCharacterLimit
    @State private var lineLimit = AcpChatRendering.assistantLineLimit

    private var rendered: AcpBoundedText {
        AcpChatRendering.bounded(
            text,
            characterLimit: characterLimit,
            lineLimit: lineLimit
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Group {
                if renderer.blocks.isEmpty, !rendered.text.isEmpty {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text("Rendering response…")
                            .font(.caption)
                            .foregroundStyle(.kaisolaSecondary)
                    }
                    .accessibilityLabel("Rendering response")
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(renderer.blocks) { block in
                            AcpTranscriptBlockView(block: block, workspaceURL: workspaceURL)
                                .equatable()
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            if rendered.isTruncated {
                Label(
                    "A bounded prefix is shown; the complete response remains available.",
                    systemImage: "ellipsis.rectangle"
                )
                .font(.caption2)
                .foregroundStyle(.kaisolaSecondary)
            }
            HStack(spacing: 10) {
                if rendered.isTruncated {
                    Button("Show more") {
                        characterLimit = AcpChatRendering.expandedLimit(characterLimit)
                        lineLimit = AcpChatRendering.expandedLimit(lineLimit)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .help("Render the next bounded portion of this response")
                }
                if characterLimit > AcpChatRendering.assistantCharacterLimit {
                    Button("Collapse") {
                        characterLimit = AcpChatRendering.assistantCharacterLimit
                        lineLimit = AcpChatRendering.assistantLineLimit
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy response", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .environment(\.openURL, OpenURLAction { link in
            AcpTranscriptLinkRouting.open(link, workspaceURL: workspaceURL)
        })
        .onAppear { renderer.submit(rendered.text) }
        .onChange(of: rendered.text) { _, source in renderer.submit(source) }
    }
}

private struct AcpTranscriptBlockView: View, Equatable {
    let block: MarkdownSourceBlock
    let workspaceURL: URL?

    var body: some View {
        switch block.block {
        case let .heading(level, text, _):
            VStack(alignment: .leading, spacing: 5) {
                Text(AcpTranscriptInlineRendering.attributed(text, workspaceURL: workspaceURL))
                    .font(headingFont(level))
                if level <= 2 { Divider() }
            }
        case let .paragraph(text, _):
            Text(AcpTranscriptInlineRendering.attributed(text, workspaceURL: workspaceURL))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .image(source, alt, _, _, _):
            Label(alt ?? source, systemImage: "photo")
                .font(.callout)
                .foregroundStyle(.kaisolaSecondary)
                .accessibilityLabel("Image reference: \(alt ?? source)")
        case let .listItem(indent, marker, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.kaisolaSecondary)
                    .frame(minWidth: 17, alignment: .trailing)
                Text(AcpTranscriptInlineRendering.attributed(text, workspaceURL: workspaceURL))
            }
            .padding(.leading, CGFloat(indent) * 18)
        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: 3)
                Text(AcpTranscriptInlineRendering.attributed(text, workspaceURL: workspaceURL))
                    .italic()
                    .foregroundStyle(.kaisolaSecondary)
            }
            .padding(.vertical, 2)
        case let .code(language, text):
            AcpTranscriptCodeBlock(languageName: language, text: text)
        case let .table(headers, rows, omittedRows):
            AcpTranscriptTable(
                headers: headers,
                rows: rows,
                omittedRows: omittedRows,
                workspaceURL: workspaceURL
            )
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        case 3: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

private struct AcpTranscriptCodeBlock: View {
    let languageName: String?
    let text: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    private var highlighted: AttributedString {
        guard let grammar = AcpTranscriptCodeLanguage.grammar(for: languageName) else {
            return AttributedString(text)
        }
        return SyntaxHighlighter.highlight(
            text,
            grammar: grammar,
            theme: colorScheme == .dark ? .dark : .light
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(languageName?.uppercased() ?? "CODE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.kaisolaSecondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityLabel(copied ? "Code copied" : "Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.45))
            ScrollView([.horizontal, .vertical]) {
                Text(highlighted)
                    .font(.system(.caption, design: .monospaced))
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 420)
        }
        .background(.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .accessibilityElement(children: .contain)
    }
}

private struct AcpTranscriptTable: View {
    let headers: [String]
    let rows: [[String]]
    let omittedRows: Int
    let workspaceURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { cells(headers, header: true) }
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow { cells(row, header: false) }
                            .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            if omittedRows > 0 {
                Label(MarkdownTableTruncation.message(omittedRows: omittedRows), systemImage: "ellipsis.rectangle")
                    .font(.caption2)
                    .foregroundStyle(.kaisolaSecondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table with \(headers.count) columns and \(rows.count) visible rows")
    }

    @ViewBuilder
    private func cells(_ values: [String], header: Bool) -> some View {
        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
            Text(AcpTranscriptInlineRendering.attributed(value, workspaceURL: workspaceURL))
                .font(.caption.weight(header ? .semibold : .regular))
                .frame(minWidth: 92, maxWidth: 260, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(header ? Color.primary.opacity(0.07) : .clear)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.55))
                        .frame(width: 1)
                }
        }
    }
}
