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
    @State private var pages: [TerminalHistoryPage] = []
    @State private var renderedPages: [Int64: String] = [:]
    @State private var isLoading = false
    @State private var didPositionAtBottom = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    private let pageBytes = 512 * 1_024
    private let bottomID = "terminal-transcript-bottom"

    var body: some View {
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
                            Text(TerminalTranscriptSearch.highlighted(
                                renderedPages[page.id] ?? "",
                                query: searchText
                            ))
                                .font(.system(size: 12, design: .monospaced))
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
        .frame(minWidth: 620, idealWidth: 820, minHeight: 440, idealHeight: 660)
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
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(statusText)
                .lineLimit(1)
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            }
            if !pages.isEmpty {
                if !searchText.isEmpty {
                    Text("\(TerminalTranscriptSearch.matchCount(in: renderedPages.values, query: searchText)) matches")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(pages.reduce(0) { $0 + $1.output.utf8.count }),
                    countStyle: .file
                ))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            if context.diskBytes > 0 {
                Label(
                    TerminalHistoryStoragePolicy.usageLabel(diskBytes: context.diskBytes),
                    systemImage: historyStorageExceeded ? "externaldrive.badge.exclamationmark" : "externaldrive"
                )
                .foregroundStyle(historyStorageExceeded ? Color.orange : Color.secondary)
                .help(TerminalHistoryStoragePolicy.help(
                    diskBytes: context.diskBytes,
                    warningMiB: settings.terminalHistoryWarningMiB
                ))
                .accessibilityLabel(TerminalHistoryStoragePolicy.help(
                    diskBytes: context.diskBytes,
                    warningMiB: settings.terminalHistoryWarningMiB
                ))
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var historyStorageExceeded: Bool {
        TerminalHistoryStoragePolicy.isExceeded(
            diskBytes: context.diskBytes,
            warningMiB: settings.terminalHistoryWarningMiB
        )
    }

    private var statusText: String {
        if let errorMessage { return errorMessage }
        guard let first = pages.first else {
            return context.endOffset == 0 ? "This terminal has no output yet." : "Loading retained history…"
        }
        if first.hasMore { return "Scroll to the top to load earlier output. The live terminal stays untouched." }
        if first.startOffset == 0, !first.truncated { return "Loaded from the terminal's first byte. The live terminal stays untouched." }
        return "Loaded all history still retained by this broker; earlier bytes are unavailable."
    }

    private var loadedPlainText: String {
        pages.compactMap { renderedPages[$0.id] }.joined()
    }

    @ViewBuilder
    private func historyBoundary(proxy: ScrollViewProxy) -> some View {
        if let first = pages.first, first.hasMore {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(isLoading ? "Loading earlier output…" : "Earlier output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        } else if let errorMessage {
            ContentUnavailableView("Could not load history", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    @MainActor
    private func loadInitial(using proxy: ScrollViewProxy) async {
        guard pages.isEmpty, !isLoading, context.endOffset > 0 else {
            didPositionAtBottom = true
            return
        }
        isLoading = true
        do {
            let page = try await model.terminalHistoryPage(
                context: context,
                beforeOffset: context.endOffset,
                maxBytes: pageBytes
            )
            pages = [page]
            await rebuildRenderedPages()
            errorMessage = nil
            await Task.yield()
            proxy.scrollTo(bottomID, anchor: .bottom)
            await Task.yield()
            didPositionAtBottom = true
        } catch {
            errorMessage = transcriptErrorDescription(error)
        }
        isLoading = false
    }

    @MainActor
    private func loadOlder(using proxy: ScrollViewProxy, preserving oldFirstID: Int64) async {
        guard !isLoading,
              let first = pages.first,
              first.id == oldFirstID,
              first.hasMore,
              first.startOffset > 0 else { return }
        isLoading = true
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
            await rebuildRenderedPages()
            errorMessage = nil
            await Task.yield()
            TerminalTranscriptScrollPolicy.preserveUserVelocity {
                proxy.scrollTo(oldFirstID, anchor: .top)
            }
        } catch {
            errorMessage = transcriptErrorDescription(error)
        }
        isLoading = false
    }

    @MainActor
    private func loadAll() async {
        guard !isLoading, var first = pages.first, first.hasMore else { return }
        isLoading = true
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
        isLoading = false
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
    }

    private func transcriptErrorDescription(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription
            ?? "The broker could not load this terminal's retained history."
    }
}

enum TerminalHistoryStoragePolicy {
    static func budgetLabel(_ warningMiB: Int) -> String {
        let value = NativePreviewSettings.clampedTerminalHistoryWarning(warningMiB)
        return value >= 1_024 ? "\(value / 1_024) GB" : "\(value) MB"
    }

    static func warningBytes(_ warningMiB: Int) -> Int64 {
        Int64(NativePreviewSettings.clampedTerminalHistoryWarning(warningMiB)) * 1_024 * 1_024
    }

    static func isExceeded(diskBytes: Int64, warningMiB: Int) -> Bool {
        max(0, diskBytes) >= warningBytes(warningMiB)
    }

    static func usageLabel(diskBytes: Int64) -> String {
        "\(ByteCountFormatter.string(fromByteCount: max(0, diskBytes), countStyle: .file)) on disk"
    }

    static func help(diskBytes: Int64, warningMiB: Int) -> String {
        let usage = usageLabel(diskBytes: diskBytes)
        let threshold = ByteCountFormatter.string(fromByteCount: warningBytes(warningMiB), countStyle: .file)
        if isExceeded(diskBytes: diskBytes, warningMiB: warningMiB) {
            return "Terminal history uses \(usage), above the \(threshold) warning. Close this terminal to reclaim it; Kaisola never deletes earlier output automatically."
        }
        return "Terminal history uses \(usage). Kaisola warns at \(threshold) and keeps the first byte until this terminal is closed."
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

enum TerminalTranscriptSearch {
    static func ranges(in text: String, query: String) -> [NSRange] {
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

    static func matchCount<S: Sequence>(in pages: S, query: String) -> Int where S.Element == String {
        pages.reduce(0) { $0 + ranges(in: $1, query: query).count }
    }

    static func highlighted(_ text: String, query: String) -> AttributedString {
        let ranges = ranges(in: text, query: query)
        guard !ranges.isEmpty else { return AttributedString(text) }
        let source = text as NSString
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
            match.backgroundColor = .yellow.opacity(0.5)
            result.append(match)
            cursor = NSMaxRange(range)
        }
        if cursor < source.length {
            result.append(AttributedString(source.substring(from: cursor)))
        }
        return result
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
        let replayInput = removingControlStrings(from: pages.joined())
        terminal.feed(buffer: Array(replayInput.utf8)[...])
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
        var cumulativeWeight = 0
        var startLine = 0
        var result = Array(repeating: "", count: pages.count)
        for index in pages.indices {
            cumulativeWeight += weights[index]
            let endLine = index == pages.index(before: pages.endIndex)
                ? lines.count
                : min(lines.count, max(startLine, lines.count * cumulativeWeight / totalWeight))
            guard endLine > startLine else { continue }
            result[index] = lines[startLine..<endLine].joined(separator: "\n")
            if endLine < lines.count { result[index].append("\n") }
            startLine = endLine
        }
        return result
    }

    /// SwiftTerm interprets CSI state, but C1 OSC/DCS scalars arrive here as
    /// decoded Unicode rather than raw single-byte controls. Remove only those
    /// non-rendering payloads (including sequences split across broker pages)
    /// before replay; CSI bytes remain intact for cursor/erase semantics.
    private static func removingControlStrings(from input: String) -> String {
        enum Mode {
            case text
            case escape
            case osc
            case oscEscape
            case controlString
            case controlStringEscape
        }

        var mode = Mode.text
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
        if case .escape = mode { result.append(UnicodeScalar(0x1B)!) }
        return String(result)
    }
}
