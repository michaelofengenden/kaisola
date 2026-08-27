import AppKit
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

/// A deliberately separate history surface. SwiftTerm owns the interactive
/// screen model; prepending historical bytes there would execute old cursor
/// movement and alternate-screen commands. This view instead pages immutable
/// broker bytes backward and renders a selectable plain-text transcript.
struct TerminalTranscriptView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: NativePreviewSettings
    let context: AppModel.TerminalTranscriptContext
    var openedFromLiveBoundary = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var pages: [TerminalHistoryPage] = []
    @State private var renderedPages: [Int64: String] = [:]
    @State private var renderedGeneration = 0
    @State private var searchWorker = TerminalTranscriptSearchWorker()
    @State private var preparedSearch: TerminalTranscriptSearchWorker.Prepared?
    @State private var searchPreparationState = TerminalTranscriptSearchPreparationState()
    @State private var searchRetryGeneration = 0
    @State private var initialLoadState = TerminalTranscriptInitialLoadState()
    @State private var isSupplementalLoading = false
    @State private var didPositionAtBottom = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    private let pageBytes = 512 * 1_024
    private let bottomID = "terminal-transcript-bottom"

    var body: some View {
        // Resolved once per body pass rather than once per page: `ForEach`
        // previously re-ran `TerminalFontOptions.resolveFont` for every
        // retained page on every render, which is wasted work identical on
        // every iteration.
        let transcriptFont = self.transcriptFont
        let searchRequest = self.searchRequest
        let searchTaskID = TerminalTranscriptSearchTaskID(
            request: searchRequest,
            retryGeneration: searchRetryGeneration
        )
        VStack(spacing: 0) {
            header
            Divider()
            statusBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        historyBoundary(proxy: proxy)
                        ForEach(pages) { page in
                            transcriptText(for: page, request: searchRequest)
                                .font(Font(transcriptFont))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 18)
                                .id(page.id)
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .padding(.vertical, 12)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .task { await loadInitial(using: proxy) }
            }
        }
        .task(id: searchTaskID) {
            await prepareSearch(for: searchRequest)
        }
        .frame(minWidth: 620, idealWidth: 820, minHeight: 440, idealHeight: 660)
    }

    /// The transcript is the same output the live surface renders, so it must
    /// obey the user's Settings → Terminal typeface, size, and weight rather
    /// than a hardcoded system-mono face. Column alignment in retained TUI
    /// frames only survives in a fixed-pitch font, which `TerminalFontOptions`
    /// guarantees for every resolution path.
    private var transcriptFont: NSFont {
        TerminalTranscriptTypography.font(
            family: settings.terminalFontFamily,
            size: settings.terminalFontSize,
            weightRaw: settings.terminalFontWeight
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(context.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(openedFromLiveBoundary
                    ? "Continuing beyond the live scroll buffer"
                    : "Read-only terminal transcript")
                    .font(.caption)
                    .foregroundStyle(.kaisolaSecondary)
            }
            Spacer()
            TextField("Search loaded", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .accessibilityLabel("Search loaded terminal transcript")
            if pages.first?.hasMore == true {
                Button {
                    Task { await loadAll() }
                } label: {
                    Image(systemName: "arrow.up.to.line.compact")
                }
                .disabled(isLoading)
                .help("Load to beginning of retained history")
                .accessibilityLabel("Load to beginning of retained history")
            }
            Button {
                let text = loadedPlainText
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .disabled(pages.isEmpty)
            .help("Copy loaded transcript")
            .accessibilityLabel("Copy loaded transcript")
            Button {
                exportLoadedTranscript()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(pages.isEmpty)
            .help("Export loaded transcript")
            .accessibilityLabel("Export loaded transcript")
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.open.display")
                .foregroundStyle(.kaisolaSecondary)
                .accessibilityHidden(true)
            Text(statusText)
                .lineLimit(1)
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            }
            if !pages.isEmpty {
                if searchRequest.hasQuery {
                    searchPreparationStatus(for: searchRequest)
                }
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(pages.reduce(0) { $0 + $1.output.utf8.count }),
                    countStyle: .file
                ))
                .monospacedDigit()
                .foregroundStyle(.kaisolaSecondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var isLoading: Bool {
        initialLoadState.isLoading || isSupplementalLoading
    }

    private var visibleErrorMessage: String? {
        initialLoadState.failureMessage ?? errorMessage
    }

    private var statusText: String {
        if let visibleErrorMessage { return visibleErrorMessage }
        guard let first = pages.first else {
            return context.endOffset == 0 ? "This terminal has no output yet." : "Loading retained history…"
        }
        if first.hasMore { return "Scroll to the top to load earlier output. The live terminal stays untouched." }
        if first.startOffset == 0, !first.truncated { return "Loaded from the terminal's first byte. The live terminal stays untouched." }
        return "Loaded all the retained history; earlier bytes are no longer available."
    }

    private var loadedPlainText: String {
        pages.compactMap { renderedPages[$0.id] }.joined()
    }

    private var searchRequest: TerminalTranscriptSearchWorker.Request {
        TerminalTranscriptSearchWorker.Request(
            query: searchText,
            generation: renderedGeneration,
            dark: colorScheme == .dark
        )
    }

    private func transcriptText(
        for page: TerminalHistoryPage,
        request: TerminalTranscriptSearchWorker.Request
    ) -> Text {
        if preparedSearch?.request == request,
           let highlighted = preparedSearch?.pages[page.id] {
            return Text(highlighted)
        }
        return Text(renderedPages[page.id] ?? "")
    }

    @ViewBuilder
    private func searchPreparationStatus(
        for request: TerminalTranscriptSearchWorker.Request
    ) -> some View {
        let presentation = searchPreparationState.presentation(for: request)
        if let visibleText = presentation.visibleText,
           let accessibilityLabel = presentation.accessibilityLabel {
            Text(visibleText)
                .monospacedDigit()
                .foregroundStyle(
                    presentation.canRetry
                        ? KaisolaStatusTone.needsYou.foregroundColor
                        : Color.kaisolaSecondary
                )
                .help(accessibilityLabel)
                .accessibilityLabel(accessibilityLabel)
            if presentation.canRetry {
                Button("Retry") {
                    searchRetryGeneration &+= 1
                }
                .controlSize(.small)
                .accessibilityIdentifier("terminal-transcript-search-retry")
                .accessibilityLabel("Retry terminal transcript search")
                .accessibilityHint("Searches the loaded transcript again without changing its selectable text")
            }
        }
    }

    @ViewBuilder
    private func historyBoundary(proxy: ScrollViewProxy) -> some View {
        if let first = pages.first, first.hasMore {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(isLoading ? "Loading earlier output…" : "Earlier output")
                    .font(.caption)
                    .foregroundStyle(.kaisolaSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .onAppear {
                guard didPositionAtBottom, !isLoading else { return }
                Task { await loadOlder(using: proxy, preserving: first.id) }
            }
        } else if let first = pages.first {
            Label(
                first.startOffset == 0 && !first.truncated
                    ? "Beginning of terminal history"
                    : "Beginning of retained history",
                systemImage: first.startOffset == 0 && !first.truncated ? "checkmark.circle" : "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.kaisolaSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        } else if let errorMessage = initialLoadState.failureMessage {
            ContentUnavailableView {
                Label("Could not load history", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Retry") {
                    Task { await loadInitial(using: proxy) }
                }
                .disabled(!initialLoadState.canRetry)
                .accessibilityIdentifier("terminal-transcript-retry")
                .accessibilityHint("Loads retained history again without changing the live terminal")
            }
                .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    @MainActor
    private func loadInitial(using proxy: ScrollViewProxy) async {
        guard let attempt = initialLoadState.begin(
            hasLoadedPages: !pages.isEmpty,
            endOffset: context.endOffset
        ) else {
            if !pages.isEmpty || context.endOffset <= 0 {
                didPositionAtBottom = true
            }
            return
        }
        errorMessage = nil
        do {
            let page = try await model.terminalHistoryPage(
                context: context,
                beforeOffset: context.endOffset,
                maxBytes: pageBytes
            )
            pages = [page]
            await renderNewPage(page)
            postInitialLoadAnnouncement(initialLoadState.finishSuccess(attempt: attempt))
            await Task.yield()
            proxy.scrollTo(bottomID, anchor: .bottom)
            await Task.yield()
            didPositionAtBottom = true
        } catch is CancellationError {
            initialLoadState.cancel(attempt: attempt)
        } catch {
            postInitialLoadAnnouncement(initialLoadState.finishFailure(
                transcriptErrorDescription(error),
                attempt: attempt
            ))
        }
    }

    @MainActor
    private func loadOlder(using proxy: ScrollViewProxy, preserving oldFirstID: Int64) async {
        guard !isLoading,
              let first = pages.first,
              first.id == oldFirstID,
              first.hasMore,
              first.startOffset > 0 else { return }
        isSupplementalLoading = true
        do {
            let page = try await model.terminalHistoryPage(
                context: context,
                beforeOffset: first.startOffset,
                maxBytes: pageBytes
            )
            guard page.endOffset == first.startOffset,
                  page.startOffset < page.endOffset,
                  !pages.contains(where: { $0.id == page.id }) else {
                throw BrokerClientError.malformedResponse
            }
            pages.insert(page, at: 0)
            await renderNewPage(page)
            errorMessage = nil
            await Task.yield()
            TerminalTranscriptScrollPolicy.preserveUserVelocity {
                proxy.scrollTo(oldFirstID, anchor: .top)
            }
        } catch {
            errorMessage = transcriptErrorDescription(error)
        }
        isSupplementalLoading = false
    }

    @MainActor
    private func loadAll() async {
        guard !isLoading, var first = pages.first, first.hasMore else { return }
        isSupplementalLoading = true
        do {
            var loaded = pages
            while first.hasMore, first.startOffset > 0 {
                try Task.checkCancellation()
                let page = try await model.terminalHistoryPage(
                    context: context,
                    beforeOffset: first.startOffset,
                    maxBytes: pageBytes
                )
                guard page.endOffset == first.startOffset,
                      page.startOffset < page.endOffset,
                      !loaded.contains(where: { $0.id == page.id }) else {
                    throw BrokerClientError.malformedResponse
                }
                loaded.insert(page, at: 0)
                first = page
                await Task.yield()
            }
            pages = loaded
            await rebuildRenderedPages()
            errorMessage = nil
        } catch is CancellationError {
            // Closing the sheet is a normal cancellation boundary.
        } catch {
            errorMessage = transcriptErrorDescription(error)
        }
        isSupplementalLoading = false
    }

    @MainActor
    private func exportLoadedTranscript() {
        let panel = NSSavePanel()
        panel.title = "Export Loaded Terminal Transcript"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = TerminalTranscriptExport.suggestedFileName(for: context.title)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try loadedPlainText.write(to: url, atomically: true, encoding: .utf8)
            errorMessage = nil
        } catch {
            errorMessage = "Could not export transcript: \(error.localizedDescription)"
        }
    }

    /// Sanitize exactly one newly fetched page and merge it into the rendered
    /// set, leaving every existing page's text byte-identical. Scroll-up
    /// paging used to replay *all* loaded pages through a fresh terminal per
    /// prepend, making deep history O(n²) in cumulative reparse and shifting
    /// already-visible text on every load (the combined replay re-apportioned
    /// lines proportionally each time). A page rendered alone still collapses
    /// cursor-addressed repaints within its own 4 MiB; what it gives up is
    /// overwrite and control state crossing this page's boundary, which is
    /// bounded to one active screen (`context.rows` lines) and one possibly
    /// truncated escape sequence — the same conditions the oldest loaded page
    /// has always started under. Load All keeps the full-fidelity combined
    /// replay below.
    @MainActor
    private func renderNewPage(_ page: TerminalHistoryPage) async {
        let output = page.output
        let isLastLoadedPage = pages.last?.id == page.id
        let columns = context.columns
        let rows = context.rows
        let plain = await Task.detached(priority: .userInitiated) {
            TerminalTranscriptSanitizer.incrementalPageText(
                output: output,
                isLastLoadedPage: isLastLoadedPage,
                columns: columns,
                rows: rows
            )
        }.value
        guard pages.contains(where: { $0.id == page.id }) else { return }
        renderedPages[page.id] = plain
        renderedGeneration &+= 1
    }

    @MainActor
    private func rebuildRenderedPages() async {
        let sourcePages = pages.map(\.output)
        let pageIDs = pages.map(\.id)
        let columns = context.columns
        let rows = context.rows
        let plain = await Task.detached(priority: .userInitiated) {
            TerminalTranscriptSanitizer.plainPages(
                sourcePages,
                columns: columns,
                rows: rows
            )
        }.value
        guard pageIDs == pages.map(\.id) else { return }
        renderedPages = Dictionary(uniqueKeysWithValues: zip(pageIDs, plain))
        renderedGeneration &+= 1
    }

    @MainActor
    private func prepareSearch(for request: TerminalTranscriptSearchWorker.Request) async {
        let attempt = searchPreparationState.begin(request: request)
        preparedSearch = nil
        guard request.hasQuery else {
            _ = searchPreparationState.finishSuccess(matchCount: 0, attempt: attempt)
            return
        }
        do {
            // Avoid queueing a full retained-history scan for every
            // intermediate keystroke. SwiftUI cancels this task whenever
            // the query, appearance, or rendered page generation changes.
            try await Task.sleep(for: .milliseconds(120))
            let snapshot = pages.compactMap { page -> TerminalTranscriptSearchWorker.Page? in
                guard let text = renderedPages[page.id] else { return nil }
                return TerminalTranscriptSearchWorker.Page(id: page.id, text: text)
            }
            let prepared = try await searchWorker.prepare(snapshot, request: request)
            try Task.checkCancellation()
            guard request == searchRequest else {
                searchPreparationState.cancel(attempt: attempt)
                return
            }
            preparedSearch = prepared
            postSearchPreparationAnnouncement(searchPreparationState.finishSuccess(
                matchCount: prepared.matchCount,
                attempt: attempt
            ))
        } catch is CancellationError {
            searchPreparationState.cancel(attempt: attempt)
        } catch {
            guard !Task.isCancelled else {
                searchPreparationState.cancel(attempt: attempt)
                return
            }
            postSearchPreparationAnnouncement(searchPreparationState.finishFailure(
                searchErrorDescription(error),
                attempt: attempt
            ))
        }
    }

    private func searchErrorDescription(_ error: any Error) -> String {
        let description = (error as? any LocalizedError)?.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let description, !description.isEmpty { return description }
        return "Search preparation failed."
    }

    private func transcriptErrorDescription(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription
            ?? "This terminal's retained history could not be loaded."
    }

    @MainActor
    private func postInitialLoadAnnouncement(
        _ announcement: TerminalTranscriptInitialLoadState.Announcement?
    ) {
        guard let announcement else { return }
        let priority: NSAccessibilityPriorityLevel = switch announcement.priority {
        case .medium: .medium
        case .high: .high
        }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement.message,
                .priority: priority.rawValue,
            ]
        )
    }

    @MainActor
    private func postSearchPreparationAnnouncement(
        _ announcement: TerminalTranscriptSearchPreparationState.Announcement?
    ) {
        guard let announcement else { return }
        let priority: NSAccessibilityPriorityLevel = switch announcement.priority {
        case .medium: .medium
        case .high: .high
        }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement.message,
                .priority: priority.rawValue,
            ]
        )
    }
}

private struct TerminalTranscriptSearchTaskID: Hashable {
    let request: TerminalTranscriptSearchWorker.Request
    let retryGeneration: Int
}

/// Keeps the retry path deterministic across SwiftUI task restarts. The view
/// clears a stale failure synchronously when `begin` accepts a retry, rejects
/// concurrent activations, and settles each accepted attempt at most once.
struct TerminalTranscriptInitialLoadState: Equatable {
    enum Attempt: Equatable {
        case initial
        case retry
    }

    struct Announcement: Equatable {
        enum Priority: Equatable {
            case medium
            case high
        }

        let message: String
        let priority: Priority
    }

    private enum Phase: Equatable {
        case idle
        case loading(Attempt, previousFailure: String?)
        case failed(String)
        case loaded
    }

    private var phase: Phase = .idle

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    var failureMessage: String? {
        if case let .failed(message) = phase { return message }
        return nil
    }

    var canRetry: Bool {
        failureMessage != nil && !isLoading
    }

    mutating func begin(hasLoadedPages: Bool, endOffset: Int64) -> Attempt? {
        guard !hasLoadedPages, endOffset > 0, !isLoading else { return nil }
        let previousFailure = failureMessage
        let attempt: Attempt = previousFailure == nil ? .initial : .retry
        phase = .loading(attempt, previousFailure: previousFailure)
        return attempt
    }

    mutating func finishSuccess(attempt: Attempt) -> Announcement? {
        guard case let .loading(activeAttempt, _) = phase,
              activeAttempt == attempt else { return nil }
        phase = .loaded
        guard attempt == .retry else { return nil }
        return Announcement(message: "Terminal history loaded.", priority: .medium)
    }

    mutating func finishFailure(_ message: String, attempt: Attempt) -> Announcement? {
        guard case let .loading(activeAttempt, _) = phase,
              activeAttempt == attempt else { return nil }
        phase = .failed(message)
        guard attempt == .retry else { return nil }
        return Announcement(
            message: "Terminal history still could not be loaded. \(message)",
            priority: .high
        )
    }

    mutating func cancel(attempt: Attempt) {
        guard case let .loading(activeAttempt, previousFailure) = phase,
              activeAttempt == attempt else { return }
        if let previousFailure {
            phase = .failed(previousFailure)
        } else {
            phase = .idle
        }
    }
}

/// Prepending a transcript page necessarily moves SwiftUI's content origin.
/// On macOS 15 and newer, ask the scroll transaction to retain an in-flight
/// trackpad gesture's velocity while restoring the old first page. macOS 14
/// keeps the already-tested anchor restoration behavior.
enum TerminalTranscriptScrollPolicy {
    static var supportsVelocityPreservation: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    @MainActor
    static func preserveUserVelocity(_ update: () -> Void) {
        var transaction = Transaction(animation: nil)
        if #available(macOS 15.0, *) {
            transaction.scrollPositionUpdatePreservesVelocity = true
        }
        withTransaction(transaction, update)
    }
}

/// Typography for the read-only history sheet, resolved from the same settings
/// the live terminal uses. Kept separate from the view so the resolution and
/// clamping rules are directly testable.
@MainActor
enum TerminalTranscriptTypography {
    static func font(family: String, size: Double, weightRaw: String) -> NSFont {
        TerminalFontOptions.resolveFont(
            family: family,
            size: clampedSize(size),
            weightRaw: weightRaw
        )
    }

    /// The transcript is selectable text rather than a terminal grid, so an
    /// out-of-range persisted size cannot break geometry — but it can still
    /// make retained history unreadable. Clamp to the range Settings offers,
    /// and treat a non-finite stored value as "never configured".
    static func clampedSize(_ size: Double) -> Double {
        guard size.isFinite else { return NativePreviewSettings.terminalFontDefault }
        return min(
            max(size, NativePreviewSettings.terminalFontRange.lowerBound),
            NativePreviewSettings.terminalFontRange.upperBound
        )
    }
}

/// View-owned state for one transcript-search request. Search preparation is
/// intentionally independent from transcript loading: a failed enhancement
/// must leave every rendered page visible and selectable, while late results
/// from an older query or sanitizer generation must not overwrite current UI.
struct TerminalTranscriptSearchPreparationState: Equatable {
    struct Attempt: Equatable {
        fileprivate let request: TerminalTranscriptSearchWorker.Request
        fileprivate let sequence: Int
    }

    struct Announcement: Equatable {
        enum Priority: Equatable {
            case medium
            case high
        }

        let message: String
        let priority: Priority
    }

    enum Presentation: Equatable {
        case hidden
        case searching
        case matches(Int)
        case unavailable(message: String)

        var visibleText: String? {
            switch self {
            case .hidden: nil
            case .searching: "Searching…"
            case let .matches(count): count == 1 ? "1 match" : "\(count) matches"
            case .unavailable: "Search unavailable"
            }
        }

        var accessibilityLabel: String? {
            switch self {
            case .hidden:
                nil
            case .searching:
                "Searching loaded terminal transcript."
            case .matches(0):
                "No matches in loaded terminal transcript."
            case .matches(1):
                "1 match in loaded terminal transcript."
            case let .matches(count):
                "\(count) matches in loaded terminal transcript."
            case let .unavailable(message):
                "Search unavailable. \(message)"
            }
        }

        var canRetry: Bool {
            if case .unavailable = self { return true }
            return false
        }
    }

    private enum Phase: Equatable {
        case idle
        case preparing(Attempt, previousFailure: String?)
        case prepared(TerminalTranscriptSearchWorker.Request, matchCount: Int)
        case failed(TerminalTranscriptSearchWorker.Request, message: String)
    }

    private var phase: Phase = .idle
    private var nextSequence = 0

    func presentation(
        for request: TerminalTranscriptSearchWorker.Request
    ) -> Presentation {
        guard request.hasQuery else { return .hidden }
        switch phase {
        case let .preparing(attempt, _) where attempt.request == request:
            return .searching
        case let .prepared(preparedRequest, matchCount) where preparedRequest == request:
            return .matches(matchCount)
        case let .failed(failedRequest, message) where failedRequest == request:
            return .unavailable(message: message)
        default:
            // A query, appearance, or rendered-generation change invalidates
            // both an old result and an old failure immediately.
            return .searching
        }
    }

    mutating func begin(request: TerminalTranscriptSearchWorker.Request) -> Attempt {
        let previousFailure: String?
        if case let .failed(failedRequest, message) = phase,
           failedRequest == request {
            previousFailure = message
        } else {
            previousFailure = nil
        }
        nextSequence &+= 1
        let attempt = Attempt(request: request, sequence: nextSequence)
        phase = .preparing(attempt, previousFailure: previousFailure)
        return attempt
    }

    mutating func finishSuccess(matchCount: Int, attempt: Attempt) -> Announcement? {
        guard case let .preparing(activeAttempt, previousFailure) = phase,
              activeAttempt == attempt else { return nil }
        let count = max(0, matchCount)
        phase = .prepared(attempt.request, matchCount: count)
        guard previousFailure != nil else { return nil }
        let matches = count == 1 ? "1 match" : "\(count) matches"
        return Announcement(
            message: "Terminal transcript search available. \(matches).",
            priority: .medium
        )
    }

    mutating func finishFailure(_ message: String, attempt: Attempt) -> Announcement? {
        guard case let .preparing(activeAttempt, previousFailure) = phase,
              activeAttempt == attempt else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = trimmed.isEmpty ? "Search preparation failed." : trimmed
        phase = .failed(attempt.request, message: failure)
        return Announcement(
            message: previousFailure == nil
                ? "Terminal transcript search unavailable. \(failure)"
                : "Terminal transcript search still unavailable. \(failure)",
            priority: .high
        )
    }

    mutating func cancel(attempt: Attempt) {
        guard case let .preparing(activeAttempt, previousFailure) = phase,
              activeAttempt == attempt else { return }
        if let previousFailure {
            phase = .failed(attempt.request, message: previousFailure)
        } else {
            phase = .idle
        }
    }
}

enum TerminalTranscriptSearch {
    private struct HighlightStyle: Sendable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    /// Find-match wash. A fixed 50%-opacity yellow was legible on the light
    /// transcript background and close to unreadable on the dark one, where
    /// the text drawn over it is nearly white. Both variants stay translucent
    /// so the match reads as a highlight behind selectable text.
    nonisolated static func matchHighlight(dark: Bool) -> NSColor {
        let style = highlightStyle(dark: dark)
        return NSColor(
            srgbRed: style.red,
            green: style.green,
            blue: style.blue,
            alpha: style.alpha
        )
    }

    private nonisolated static func highlightStyle(dark: Bool) -> HighlightStyle {
        dark
            ? HighlightStyle(red: 0.98, green: 0.80, blue: 0.24, alpha: 0.30)
            : HighlightStyle(red: 1.0, green: 0.87, blue: 0.19, alpha: 0.55)
    }

    nonisolated static func ranges(in text: String, query: String) -> [NSRange] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let source = text as NSString
        var cursor = 0
        var result: [NSRange] = []
        while cursor < source.length {
            let range = source.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: NSRange(location: cursor, length: source.length - cursor)
            )
            guard range.location != NSNotFound, range.length > 0 else { break }
            result.append(range)
            cursor = NSMaxRange(range)
        }
        return result
    }

    nonisolated static func matchCount<S: Sequence>(in pages: S, query: String) -> Int where S.Element == String {
        pages.reduce(0) { $0 + ranges(in: $1, query: query).count }
    }

    nonisolated static func highlighted(
        _ text: String,
        query: String,
        dark: Bool
    ) -> (text: AttributedString, matchCount: Int) {
        let ranges = ranges(in: text, query: query)
        guard !ranges.isEmpty else { return (AttributedString(text), 0) }
        let source = text as NSString
        let style = highlightStyle(dark: dark)
        let highlight = Color(
            .sRGB,
            red: style.red,
            green: style.green,
            blue: style.blue,
            opacity: style.alpha
        )
        var result = AttributedString()
        var cursor = 0
        for range in ranges {
            if range.location > cursor {
                result.append(AttributedString(source.substring(with: NSRange(
                    location: cursor,
                    length: range.location - cursor
                ))))
            }
            var match = AttributedString(source.substring(with: range))
            match.backgroundColor = highlight
            result.append(match)
            cursor = NSMaxRange(range)
        }
        if cursor < source.length {
            result.append(AttributedString(source.substring(from: cursor)))
        }
        return (result, ranges.count)
    }
}

/// View-lifetime cache for selectable transcript text and its find highlights.
/// Actor isolation keeps Unicode matching and attributed-string construction
/// off the main actor; the request generation prevents a cached result from a
/// prior sanitizer pass from being reused after older pages are prepended.
actor TerminalTranscriptSearchWorker {
    typealias PreparationGate = @Sendable (_ request: Request, _ attempt: Int) throws -> Void

    struct Page: Sendable {
        let id: Int64
        let text: String
    }

    struct Request: Hashable, Sendable {
        let query: String
        let generation: Int
        let dark: Bool

        init(query: String, generation: Int, dark: Bool) {
            self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            self.generation = generation
            self.dark = dark
        }

        var hasQuery: Bool { !query.isEmpty }
    }

    struct Prepared: Sendable {
        let request: Request
        let pages: [Int64: AttributedString]
        let matchCount: Int
    }

    private let preparationGate: PreparationGate
    private var cached: Prepared?
    private var preparationAttemptCount = 0
    private(set) var preparationCount = 0

    init(preparationGate: @escaping PreparationGate = { _, _ in }) {
        self.preparationGate = preparationGate
    }

    func prepare(_ sourcePages: [Page], request: Request) async throws -> Prepared {
        try Task.checkCancellation()
        if let cached, cached.request == request { return cached }
        preparationAttemptCount += 1
        try preparationGate(request, preparationAttemptCount)
        try Task.checkCancellation()

        var pages: [Int64: AttributedString] = [:]
        pages.reserveCapacity(sourcePages.count)
        var matchCount = 0
        for page in sourcePages {
            try Task.checkCancellation()
            let highlighted = TerminalTranscriptSearch.highlighted(
                page.text,
                query: request.query,
                dark: request.dark
            )
            pages[page.id] = highlighted.text
            matchCount += highlighted.matchCount
        }
        try Task.checkCancellation()

        let prepared = Prepared(request: request, pages: pages, matchCount: matchCount)
        cached = prepared
        preparationCount += 1
        return prepared
    }
}

enum TerminalTranscriptExport {
    static func suggestedFileName(for title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let stem = title.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let compact = String(stem)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return "\(compact.isEmpty ? "terminal" : compact)-transcript.txt"
    }
}

/// Stateful OSC/DCS/APC/PM/SOS filtering for retained transcript chunks. A
/// broker page may end halfway through ESC ] ... ST, so each chunk resumes the
/// previous parser mode while still returning a page-bounded String for replay.
struct TerminalControlStringFilter {
    private enum Mode {
        case text
        case escape
        case osc
        case oscEscape
        case controlString
        case controlStringEscape
    }

    private var mode = Mode.text

    mutating func consume(_ input: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in input.unicodeScalars {
            let value = scalar.value
            switch mode {
            case .text:
                switch value {
                case 0x1B: mode = .escape
                case 0x9D: mode = .osc
                case 0x90, 0x98, 0x9E, 0x9F: mode = .controlString
                default: result.append(scalar)
                }
            case .escape:
                switch value {
                case 0x5D: mode = .osc
                case 0x50, 0x58, 0x5E, 0x5F: mode = .controlString
                default:
                    result.append(UnicodeScalar(0x1B)!)
                    result.append(scalar)
                    mode = .text
                }
            case .osc:
                if value == 0x07 || value == 0x9C { mode = .text }
                else if value == 0x1B { mode = .oscEscape }
            case .oscEscape:
                mode = value == 0x5C ? .text : .osc
            case .controlString:
                if value == 0x1B { mode = .controlStringEscape }
                else if value == 0x9C { mode = .text }
            case .controlStringEscape:
                mode = value == 0x5C ? .text : .controlString
            }
        }
        return String(result)
    }

    /// Preserve a lone trailing ESC because it may be ordinary terminal input;
    /// unterminated control strings remain deliberately non-rendering.
    mutating func finish() -> String {
        defer { mode = .text }
        if case .escape = mode { return "\u{1B}" }
        return ""
    }
}

/// Replays immutable output through Kaisola's production terminal parser, then
/// exposes the normal scrollback as selectable plain text. A strip-only parser
/// made cursor-addressed progress/TUI frames read as `W-Wo-Wor-Working`; replay
/// preserves overwrite/erase semantics without touching the live terminal. The
/// final text is apportioned across the original stable page ids so prepend
/// anchoring remains page-native.
enum TerminalTranscriptSanitizer {
    private final class ReplayDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {
            // Device-status replies from replay must never reach the live PTY.
        }
    }

    static func plainPages(
        _ pages: [String],
        columns: Int = 160,
        rows: Int = 60
    ) -> [String] {
        guard !pages.isEmpty else { return [] }

        let delegate = ReplayDelegate()
        let options = TerminalOptions(
            cols: min(max(columns, 2), 1_000),
            rows: min(max(rows, 1), 1_000),
            scrollback: 100_000
        )
        let terminal = Terminal(delegate: delegate, options: options)
        var filter = TerminalControlStringFilter()
        for page in pages {
            let replayInput = filter.consume(page)
            if !replayInput.isEmpty {
                terminal.feed(buffer: Array(replayInput.utf8)[...])
            }
        }
        let trailingInput = filter.finish()
        if !trailingInput.isEmpty {
            terminal.feed(buffer: Array(trailingInput.utf8)[...])
        }
        let replayed = terminal.getText(
            start: Position(col: 0, row: 0),
            end: Position(col: terminal.cols, row: Int.max)
        )
        var lines = replayed
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if let firstContent = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), firstContent > 0 {
            lines = Array(lines[firstContent...])
        }
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return Array(repeating: "", count: pages.count) }

        let weights = pages.map { max(1, $0.utf8.count) }
        let totalWeight = weights.reduce(0, +)
        return apportion(lines: lines, weights: weights, totalWeight: totalWeight, pageCount: pages.count)
    }

    /// Render one page so it joins an already-rendered transcript without
    /// touching the other pages: single-page replay, plus the same trailing
    /// newline the combined apportionment gives every non-final page so
    /// adjacent page texts never run together in the joined transcript.
    static func incrementalPageText(
        output: String,
        isLastLoadedPage: Bool,
        columns: Int = 160,
        rows: Int = 60
    ) -> String {
        let plain = plainPages([output], columns: columns, rows: rows).first ?? ""
        guard !plain.isEmpty, !isLastLoadedPage else { return plain }
        return plain + "\n"
    }

    private static func apportion(
        lines: [String],
        weights: [Int],
        totalWeight: Int,
        pageCount: Int
    ) -> [String] {
        var cumulativeWeight = 0
        var startLine = 0
        var result = Array(repeating: "", count: pageCount)
        for index in 0..<pageCount {
            cumulativeWeight += weights[index]
            let endLine = index == pageCount - 1
                ? lines.count
                : min(lines.count, max(startLine, lines.count * cumulativeWeight / totalWeight))
            guard endLine > startLine else { continue }
            result[index] = lines[startLine..<endLine].joined(separator: "\n")
            if endLine < lines.count { result[index].append("\n") }
            startLine = endLine
        }
        return result
    }

}
