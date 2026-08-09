import AppKit
import CryptoKit
import Foundation
import SwiftUI
import WebKit

// Standalone preview surfaces for structured files (CSV/TSV, JSON, HTML). These
// are pure, self-contained views the workspace's `FilePreviewView` wires in by
// file extension. Parsing/tree-building is factored into `CsvTable` / `JsonTree`
// so it is testable without touching SwiftUI or WebKit.

// MARK: - Parse caching

/// Cheap task identity supplied by the mounted file preview. The path and mtime
/// distinguish disk snapshots without hashing a 1 MiB source string on every
/// SwiftUI body evaluation; revision covers every committed load and explicit
/// in-place HTML reload.
struct PreviewParseIdentity: Hashable, Sendable {
    let path: String
    let modificationDate: Date?
    let revision: Int
}

/// A view-lifetime actor cache keyed by content identity.
///
/// SwiftUI re-evaluates `body` for reasons that have nothing to do with the
/// document — a tab-strip hover, a window resize, a zoom step, a sibling's state
/// change. Re-parsing a multi-megabyte CSV or JSON payload on each of those
/// turns a linear parser into visible interaction jank, which is exactly what
/// hovering the file tabs over a 1 MiB CSV used to cost. Actor isolation also
/// keeps the first parse/tree/readiness pass off the main actor.
///
/// Identity is the source text itself: SwiftUI hands the same String storage
/// back on a re-render, so the equality check is a pointer comparison in the
/// common case and a full compare only when the document really changed. One
/// entry is enough — a preview shows one document at a time, and the view's
/// `@State` is discarded when it is retargeted at another file.
actor PreviewParseCache<Value: Sendable> {
    private var source: String?
    private var cached: Value?
    /// Test-visible proof that repeated body evaluations do not re-parse.
    private(set) var parseCount = 0

    init() {}

    func value(
        for source: String,
        parse: @Sendable (String) -> Value
    ) -> Value {
        if let cached, self.source == source { return cached }
        let parsed = parse(source)
        self.source = source
        cached = parsed
        parseCount += 1
        return parsed
    }
}

// MARK: - CSV

/// RFC-4180-ish CSV/TSV parsing. Pure so tests can drive it directly.
enum CsvTable {
    struct Truncation: Equatable, Sendable {
        let actualRowCount: Int
        let displayedRowCount: Int
        let actualColumnCount: Int
        let displayedColumnCount: Int

        static let empty = Truncation(
            actualRowCount: 0,
            displayedRowCount: 0,
            actualColumnCount: 0,
            displayedColumnCount: 0
        )

        var rowsWereTruncated: Bool { actualRowCount > displayedRowCount }
        var columnsWereTruncated: Bool { actualColumnCount > displayedColumnCount }
        var isTruncated: Bool { rowsWereTruncated || columnsWereTruncated }

        /// A dimension-specific summary for the visible warning. Counts name
        /// both the retained grid and the complete parsed document so the
        /// warning never implies missing rows for a column-only truncation.
        var notice: String? {
            switch (rowsWereTruncated, columnsWereTruncated) {
            case (true, true):
                "Showing \(displayedRowCount) of \(actualRowCount) rows and "
                    + "\(displayedColumnCount) of \(actualColumnCount) columns."
            case (true, false):
                "Showing \(displayedRowCount) of \(actualRowCount) rows."
            case (false, true):
                "Showing \(displayedColumnCount) of \(actualColumnCount) columns."
            case (false, false):
                nil
            }
        }
    }

    struct ParseResult: Equatable, Sendable {
        let rows: [[String]]
        let truncation: Truncation

        var truncated: Bool { truncation.isTruncated }
    }

    /// Rendering caps: excess rows/columns are dropped and flagged so a
    /// pathological file can never realize an unbounded grid.
    static let maxRows = 2_000
    static let maxCols = 64

    /// Forward-only access to borrowed UTF-8 storage. Production uses either a
    /// contiguous view of the source or the source's own `String.UTF8View`, so
    /// parsing never begins by materializing the document as `[Character]`.
    struct UTF8Cursor<Source: Collection> where Source.Element == UInt8 {
        private let source: Source
        private var index: Source.Index

        init(_ source: Source) {
            self.source = source
            index = source.startIndex
        }

        func peek() -> UInt8? {
            guard index != source.endIndex else { return nil }
            return source[index]
        }

        @discardableResult
        mutating func take() -> UInt8? {
            guard index != source.endIndex else { return nil }
            let byte = source[index]
            index = source.index(after: index)
            return byte
        }

        /// Consume `bytes` only when the complete sequence is next. A failed
        /// lookahead leaves the cursor unchanged.
        mutating func consume(_ bytes: ArraySlice<UInt8>) -> Bool {
            var candidate = index
            for expected in bytes {
                guard candidate != source.endIndex, source[candidate] == expected else {
                    return false
                }
                candidate = source.index(after: candidate)
            }
            index = candidate
            return true
        }
    }

    /// Parse `text` into rows of fields. Handles quoted fields, `""`-escaped
    /// quotes, embedded newlines inside quotes, and CRLF/CR/LF record endings.
    /// Returns the capped rows plus separate actual/displayed dimensions for
    /// rows and columns. Counting continues after either render cap is reached,
    /// but discarded field contents are never retained.
    ///
    /// Pure — `nonisolated` keeps CI's strict-concurrency inference from pinning
    /// it to the main actor just because the file also defines SwiftUI views.
    nonisolated static func parse(_ text: String, delimiter: Character = ",") -> ParseResult {
        // A Character can contain multiple UTF-8 bytes. Delimiters used by the
        // preview are ASCII, but preserving the public parser contract costs
        // only this tiny, delimiter-sized buffer.
        let delimiterBytes = Array(String(delimiter).utf8)

        // Native Swift strings normally expose contiguous UTF-8 storage. Parse
        // that storage in place for an integer-indexed hot loop, while retaining
        // a single-pass view fallback for strings without contiguous storage.
        if let result = text.utf8.withContiguousStorageIfAvailable({ bytes in
            parse(bytes, delimiterBytes: delimiterBytes)
        }) {
            return result
        }
        return parse(text.utf8, delimiterBytes: delimiterBytes)
    }

    private nonisolated static func parse<Source: Collection>(
        _ source: Source,
        delimiterBytes: [UInt8]
    ) -> ParseResult where Source.Element == UInt8 {
        var cursor = UTF8Cursor(source)
        var rows: [[String]] = []
        var record: [String] = []
        var fieldBytes: [UInt8] = []
        // Once a row or column is outside the render cap its value is not
        // retained. This separate flag preserves field-start quote semantics
        // even when `field` deliberately stays empty.
        var fieldIsEmpty = true
        var fieldCount = 0
        var actualRowCount = 0
        var actualColumnCount = 0
        var inQuotes = false

        func appendToField(_ byte: UInt8) {
            if rows.count < maxRows, record.count < maxCols {
                fieldBytes.append(byte)
            }
            fieldIsEmpty = false
        }

        func endField() {
            fieldCount += 1
            if rows.count < maxRows, record.count < maxCols {
                record.append(String(decoding: fieldBytes, as: UTF8.self))
            }
            fieldBytes.removeAll(keepingCapacity: true)
            fieldIsEmpty = true
        }
        func endRecord() {
            endField()
            actualRowCount += 1
            actualColumnCount = max(actualColumnCount, fieldCount)
            if rows.count < maxRows {
                rows.append(record)
            }
            record = []
            fieldCount = 0
        }

        while let byte = cursor.take() {
            if inQuotes {
                if byte == 0x22 {
                    // A doubled quote inside a quoted field is a literal quote;
                    // a lone quote closes the field.
                    if cursor.peek() == 0x22 {
                        appendToField(0x22)
                        cursor.take()
                    } else {
                        inQuotes = false
                    }
                } else {
                    appendToField(byte)
                }
                continue
            }

            if byte == 0x22, fieldIsEmpty {
                // A quote opens a quoted field ONLY at field start (RFC-4180).
                // A quote mid-field (e.g. 3"5) is a literal character — handled
                // by `default` — so one stray quote can't swallow the rest of
                // the file into a single never-closed field.
                inQuotes = true
            } else if byte == delimiterBytes[0],
                      delimiterBytes.count == 1 || cursor.consume(delimiterBytes.dropFirst()) {
                endField()
            } else if byte == 0x0D {
                // Treat CRLF as one record separator while retaining both
                // bytes verbatim when the pair appears inside a quoted field.
                if cursor.peek() == 0x0A {
                    cursor.take()
                }
                endRecord()
            } else if byte == 0x0A {
                endRecord()
            } else {
                appendToField(byte)
            }
        }

        // Flush a trailing record only when real data is pending, so a file that
        // ends on a newline does not yield a spurious empty final row.
        if !fieldIsEmpty || fieldCount > 0 {
            endRecord()
        }
        let displayedColumnCount = rows.reduce(0) { max($0, $1.count) }
        return ParseResult(
            rows: rows,
            truncation: Truncation(
                actualRowCount: actualRowCount,
                displayedRowCount: rows.count,
                actualColumnCount: actualColumnCount,
                displayedColumnCount: displayedColumnCount
            )
        )
    }

    /// Guess the delimiter from the first non-empty line by counting comma,
    /// semicolon, and tab occurrences outside quotes. Comma wins ties and is the
    /// fallback when no delimiter is present.
    nonisolated static func detectDelimiter(_ text: String) -> Character {
        let candidates: [Character] = [",", ";", "\t"]
        let firstLine = text.split(
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isNewline }
        ).first ?? ""

        var counts: [Character: Int] = [:]
        var inQuotes = false
        for character in firstLine {
            if character == "\"" {
                inQuotes.toggle()
            } else if !inQuotes, candidates.contains(character) {
                counts[character, default: 0] += 1
            }
        }

        var best: Character = ","
        var bestCount = 0
        for candidate in candidates where (counts[candidate] ?? 0) > bestCount {
            best = candidate
            bestCount = counts[candidate] ?? 0
        }
        return best
    }
}

/// The render-ready projection of a CSV/TSV document: capped rows, exact
/// truncation dimensions, and fixed per-column widths that keep cells aligned
/// across a vertically lazy list. Built once per content identity — this used
/// to run in `CsvPreview.init`, so every SwiftUI body evaluation re-parsed the
/// whole file.
struct CsvPreviewModel: Equatable, Sendable {
    static let minimumColumnWidth: CGFloat = 46
    static let maximumColumnWidth: CGFloat = 340
    /// ~advance of SF Mono 12pt, the cell font.
    static let characterWidth: CGFloat = 7.3
    static let cellPadding: CGFloat = 10

    let rows: [[String]]
    let truncation: CsvTable.Truncation
    let columnWidths: [CGFloat]

    var truncated: Bool { truncation.isTruncated }

    static let empty = CsvPreviewModel(rows: [], truncation: .empty, columnWidths: [])

    nonisolated static func make(_ text: String) -> CsvPreviewModel {
        let parsed = CsvTable.parse(text, delimiter: CsvTable.detectDelimiter(text))
        let columnCount = parsed.truncation.displayedColumnCount
        var widths = [CGFloat](repeating: minimumColumnWidth, count: columnCount)
        for row in parsed.rows {
            for (column, value) in row.enumerated() where column < columnCount {
                let fitted = min(
                    maximumColumnWidth,
                    max(minimumColumnWidth, CGFloat(value.count) * characterWidth + cellPadding * 2)
                )
                if fitted > widths[column] { widths[column] = fitted }
            }
        }
        return CsvPreviewModel(rows: parsed.rows, truncation: parsed.truncation, columnWidths: widths)
    }
}

/// Stable, lossless metadata for one visible CSV cell. The coordinate-based
/// identity keeps duplicate values distinct and remains stable while a value is
/// disclosed; the full source value never depends on the table's visual
/// truncation.
struct CsvCellInspection: Equatable, Sendable, Identifiable {
    struct ID: Hashable, Sendable {
        let rowIndex: Int
        let columnIndex: Int
    }

    let id: ID
    let value: String
    private let rowAccessibilityLabel: String

    init(
        rowIndex: Int,
        columnIndex: Int,
        value: String,
        rowAccessibilityLabel: String? = nil
    ) {
        id = ID(rowIndex: rowIndex, columnIndex: columnIndex)
        self.value = value
        self.rowAccessibilityLabel = rowAccessibilityLabel ?? "Row \(rowIndex + 1)"
    }

    var accessibilityLabel: String {
        "\(rowAccessibilityLabel), column \(id.columnIndex + 1)"
    }

    var accessibilityValue: String {
        value.isEmpty ? "Empty cell" : value
    }

    var accessibilityHint: String {
        "Press Return to inspect the complete value and copy it."
    }
}

/// A small seam keeps exact-value clipboard behavior deterministic in tests and
/// lets the UI surface pasteboard refusal instead of claiming a copy succeeded.
enum CsvCellClipboard {
    @discardableResult
    static func copy(_ value: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
    }
}

enum CsvHeaderMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case firstRowIsHeader
    case noHeader

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Auto"
        case .firstRowIsHeader: "First Row Is Header"
        case .noHeader: "No Header"
        }
    }
}

struct CsvHeaderResolution: Equatable, Sendable {
    let mode: CsvHeaderMode
    let hasHeader: Bool

    init(mode: CsvHeaderMode, rows: [[String]]) {
        self.mode = mode
        switch mode {
        case .automatic:
            hasHeader = Self.automaticHeaderEvidence(in: rows)
        case .firstRowIsHeader:
            hasHeader = !rows.isEmpty
        case .noHeader:
            hasHeader = false
        }
    }

    func isHeader(rowIndex: Int) -> Bool {
        hasHeader && rowIndex == 0
    }

    func dataRowNumber(rowIndex: Int) -> Int? {
        guard rowIndex >= 0 else { return nil }
        if hasHeader {
            return rowIndex == 0 ? nil : rowIndex
        }
        return rowIndex + 1
    }

    func accessibilityLabel(rowIndex: Int, columnIndex: Int) -> String {
        if isHeader(rowIndex: rowIndex) {
            return "Header, column \(columnIndex + 1)"
        }
        return "Row \(dataRowNumber(rowIndex: rowIndex) ?? rowIndex + 1), column \(columnIndex + 1)"
    }

    /// Automatic mode only promotes row zero when a later value supplies
    /// concrete type evidence (for example `age` followed by `36`). Ambiguous
    /// all-text tables remain data rows until the user explicitly opts in.
    private static func automaticHeaderEvidence(in rows: [[String]]) -> Bool {
        guard rows.count > 1 else { return false }
        let first = rows[0]
        let second = rows[1]
        let comparableColumns = min(first.count, second.count)
        guard comparableColumns > 0 else { return false }
        return (0..<comparableColumns).contains { column in
            let candidate = first[column].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = second[column].trimmingCharacters(in: .whitespacesAndNewlines)
            return !candidate.isEmpty
                && !Self.isTypedData(candidate)
                && Self.isTypedData(value)
        }
    }

    private static func isTypedData(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if Double(value) != nil { return true }
        switch value.lowercased() {
        case "true", "false", "yes", "no", "null", "nil": return true
        default: return false
        }
    }
}

/// Per-document preference storage. The key contains only a SHA-256 digest of
/// the standardized path, so UserDefaults never becomes an absolute-path
/// inventory. Automatic is the implicit default and removes any stored value.
final class CsvHeaderPreferenceStore: @unchecked Sendable {
    static let shared = CsvHeaderPreferenceStore()

    private static let keyPrefix = "csvHeaderMode.v1."
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func mode(forPath path: String) -> CsvHeaderMode {
        guard let rawValue = defaults.string(forKey: key(forPath: path)) else {
            return .automatic
        }
        return CsvHeaderMode(rawValue: rawValue) ?? .automatic
    }

    func set(_ mode: CsvHeaderMode, forPath path: String) {
        let key = key(forPath: path)
        if mode == .automatic {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(mode.rawValue, forKey: key)
        }
    }

    private func key(forPath path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(standardized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return Self.keyPrefix + digest
    }
}

/// A scrollable table for CSV/TSV text. Header semantics are inferred or
/// explicitly selected per document; cells are monospaced 12pt with fixed
/// per-column widths so columns align across a vertically lazy list.
struct CsvPreview: View {
    let text: String
    let identity: PreviewParseIdentity
    private let preferenceStore: CsvHeaderPreferenceStore

    @State private var cache = PreviewParseCache<CsvPreviewModel>()
    @State private var model: CsvPreviewModel?
    @State private var preparedIdentity: PreviewParseIdentity?
    @State private var inspectedCell: CsvCellInspection?
    @State private var headerMode: CsvHeaderMode
    @FocusState private var focusedCellID: CsvCellInspection.ID?

    private static let cellFont = Font.system(size: 12, design: .monospaced)

    init(
        text: String,
        identity: PreviewParseIdentity,
        preferenceStore: CsvHeaderPreferenceStore = .shared
    ) {
        self.text = text
        self.identity = identity
        self.preferenceStore = preferenceStore
        _headerMode = State(initialValue: preferenceStore.mode(forPath: identity.path))
    }

    var body: some View {
        Group {
            if preparedIdentity == identity, let model {
                table(model)
            } else {
                ProgressView("Preparing table…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: identity) {
            // A retargeted preview must never keep disclosing a value from the
            // previous document while its replacement is parsing.
            inspectedCell = nil
            focusedCellID = nil
            headerMode = preferenceStore.mode(forPath: identity.path)
            let source = text
            let parsed = await cache.value(for: source, parse: CsvPreviewModel.make)
            guard !Task.isCancelled else { return }
            model = parsed
            preparedIdentity = identity
        }
    }

    private func table(_ model: CsvPreviewModel) -> some View {
        let headerResolution = CsvHeaderResolution(mode: headerMode, rows: model.rows)
        return VStack(alignment: .leading, spacing: 0) {
            headerControls(headerResolution)
            if let notice = model.truncation.notice { truncationNotice(notice) }
            if model.rows.isEmpty {
                ContentUnavailableView(
                    "Empty file",
                    systemImage: "tablecells",
                    description: Text("No rows to display.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                            rowView(
                                row,
                                rowIndex: index,
                                columnWidths: model.columnWidths,
                                headerResolution: headerResolution
                            )
                            Divider()
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func headerControls(_ resolution: CsvHeaderResolution) -> some View {
        HStack(spacing: 8) {
            Text("Header Row")
                .font(.caption.weight(.medium))
            Picker("Header Row", selection: headerModeSelection) {
                ForEach(CsvHeaderMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel("CSV header row")
            .accessibilityValue(headerMode.title)
            .accessibilityIdentifier("csv.headerMode")
            if headerMode == .automatic {
                Text(resolution.hasHeader ? "Header detected" : "No header detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        resolution.hasHeader
                            ? "Auto detected a header row"
                            : "Auto detected no header row"
                    )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.035))
    }

    private var headerModeSelection: Binding<CsvHeaderMode> {
        Binding(
            get: { headerMode },
            set: { mode in
                headerMode = mode
                preferenceStore.set(mode, forPath: identity.path)
            }
        )
    }

    private func rowView(
        _ row: [String],
        rowIndex: Int,
        columnWidths: [CGFloat],
        headerResolution: CsvHeaderResolution
    ) -> some View {
        let isHeader = headerResolution.isHeader(rowIndex: rowIndex)
        let dataRowNumber = headerResolution.dataRowNumber(rowIndex: rowIndex)
        return HStack(spacing: 0) {
            Text(isHeader ? "Header" : String(dataRowNumber ?? rowIndex + 1))
                .font(.caption2.monospacedDigit().weight(isHeader ? .semibold : .regular))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
                .padding(.trailing, 8)
                .help(isHeader ? "Header row" : "Data row \(dataRowNumber ?? rowIndex + 1)")
                .accessibilityHidden(true)
            ForEach(Array(columnWidths.enumerated()), id: \.offset) { column, width in
                cell(
                    CsvCellInspection(
                        rowIndex: rowIndex,
                        columnIndex: column,
                        value: column < row.count ? row[column] : "",
                        rowAccessibilityLabel: isHeader
                            ? "Header"
                            : "Row \(dataRowNumber ?? rowIndex + 1)"
                    ),
                    width: width,
                    isHeader: isHeader
                )
            }
        }
        .background(isHeader ? Color.secondary.opacity(0.15) : Color.clear)
    }

    private func cell(
        _ inspection: CsvCellInspection,
        width: CGFloat,
        isHeader: Bool
    ) -> some View {
        Button {
            inspectedCell = inspection
        } label: {
            Text(inspection.value)
                .font(Self.cellFont)
                .fontWeight(isHeader ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, CsvPreviewModel.cellPadding)
                .padding(.vertical, 5)
                .frame(width: width, alignment: .leading)
                .contentShape(Rectangle())
                // A trailing hairline as a column separator; an overlay matches
                // the cell's height exactly, avoiding the ambiguity a bare
                // Divider has inside an HStack.
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                }
                .overlay {
                    if focusedCellID == inspection.id {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .padding(1)
                    }
                }
        }
        .buttonStyle(.plain)
        .focused($focusedCellID, equals: inspection.id)
        .help("Inspect complete cell value")
        .accessibilityLabel(inspection.accessibilityLabel)
        .accessibilityValue(inspection.accessibilityValue)
        .accessibilityHint(inspection.accessibilityHint)
        .accessibilityAction(named: Text("Copy Cell")) {
            copyCell(inspection)
        }
        .contextMenu {
            Button("Copy Cell") { copyCell(inspection) }
        }
        .popover(isPresented: inspectionBinding(for: inspection), arrowEdge: .bottom) {
            cellInspector(inspection)
        }
    }

    private func inspectionBinding(for inspection: CsvCellInspection) -> Binding<Bool> {
        Binding(
            get: { inspectedCell?.id == inspection.id },
            set: { isPresented in
                if !isPresented, inspectedCell?.id == inspection.id {
                    inspectedCell = nil
                }
            }
        )
    }

    private func cellInspector(_ inspection: CsvCellInspection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Complete Cell Value")
                        .font(.headline)
                    Text(inspection.accessibilityLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy Cell") { copyCell(inspection) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Done") { inspectedCell = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                if inspection.value.isEmpty {
                    Text("Empty cell")
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    Text(inspection.value)
                        .font(Self.cellFont)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(12)
                        .accessibilityLabel("Complete cell value")
                        .accessibilityValue(inspection.value)
                }
            }
            .frame(minWidth: 360, idealWidth: 520, maxWidth: 640)
            .frame(minHeight: 160, idealHeight: 280, maxHeight: 420)
        }
    }

    private func copyCell(_ inspection: CsvCellInspection) {
        if CsvCellClipboard.copy(inspection.value) {
            ToastCenter.shared.show("Copied cell", style: .success)
        } else {
            ToastCenter.shared.show("Could not copy cell", style: .error)
        }
    }

    private func truncationNotice(_ notice: String) -> some View {
        Label(
            notice,
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.14))
    }
}

// MARK: - JSON

/// Pure builder that turns a `JSONSerialization` value into a display tree,
/// bounded by depth and total-node caps. Factored out of the view so tests can
/// assert node counts, caps, and labels without SwiftUI.
enum JsonTree {
    static let maxDepth = 12
    static let maxNodes = 2_000

    /// The identity of the root value. Child paths extend it with `.key` for
    /// object members and `[index]` for array elements.
    static let rootPath = "$"

    /// One node in the rendered JSON tree. A reference type so SwiftUI can hold
    /// stable identities across expand/collapse.
    final class Node: Identifiable, @unchecked Sendable {
        enum Kind: Equatable, Sendable { case object, array, string, number, bool, null, truncated }

        /// The path to this value (`$.meta.items[3]`), not a fresh `UUID`.
        /// Disclosure state is keyed by node identity, so a rebuilt tree — a
        /// re-render, a reload, a returning tab — must reuse the same ids or
        /// every expanded object silently snaps shut.
        let id: String
        /// Object key or `[index]` label; `nil` for the root value.
        let key: String?
        /// Scalar text, or a `{n}` / `[n]` container summary.
        let display: String
        let kind: Kind
        let children: [Node]
        let isTruncationMarker: Bool

        init(
            id: String,
            key: String?,
            display: String,
            kind: Kind,
            children: [Node] = [],
            isTruncationMarker: Bool = false
        ) {
            self.id = id
            self.key = key
            self.display = display
            self.kind = kind
            self.children = children
            self.isTruncationMarker = isTruncationMarker
        }

        /// Total nodes in this subtree, inclusive of the receiver.
        var totalNodes: Int { 1 + children.reduce(0) { $0 + $1.totalNodes } }

        /// Whether any node in this subtree marks a dropped-for-cap boundary.
        var containsTruncation: Bool {
            isTruncationMarker || children.contains { $0.containsTruncation }
        }
    }

    /// Build a display tree from a `JSONSerialization` value (NSDictionary /
    /// NSArray / NSNumber / NSString / NSNull, or their Swift bridges). Beyond
    /// `maxDepth` levels or `maxNodes` total nodes, growth stops and a single
    /// truncation-marker node is inserted so the UI can flag it.
    nonisolated static func build(_ data: Any, key: String? = nil) -> Node {
        var count = 0
        return build(data, key: key, path: rootPath, depth: 0, count: &count)
    }

    /// The identity of a container's truncation marker. Object children always
    /// join with `.` and array children with `[`, so a suffix using neither can
    /// never collide with a real member — including a key literally named
    /// `truncated`.
    nonisolated private static func truncationPath(_ path: String) -> String {
        path + "|truncated"
    }

    nonisolated private static func build(
        _ data: Any,
        key: String?,
        path: String,
        depth: Int,
        count: inout Int
    ) -> Node {
        count += 1
        if depth > maxDepth {
            return Node(id: path, key: key, display: "…", kind: .truncated, isTruncationMarker: true)
        }

        switch data {
        case let dictionary as [String: Any]:
            var children: [Node] = []
            for childKey in dictionary.keys.sorted() {
                if count >= maxNodes {
                    let remaining = dictionary.count - children.count
                    children.append(Node(
                        id: truncationPath(path),
                        key: nil,
                        display: "… \(remaining) more",
                        kind: .truncated,
                        isTruncationMarker: true
                    ))
                    break
                }
                children.append(build(
                    dictionary[childKey] as Any,
                    key: childKey,
                    path: "\(path).\(childKey)",
                    depth: depth + 1,
                    count: &count
                ))
            }
            return Node(id: path, key: key, display: "{\(dictionary.count)}", kind: .object, children: children)

        case let array as [Any]:
            var children: [Node] = []
            for (index, element) in array.enumerated() {
                if count >= maxNodes {
                    children.append(Node(
                        id: truncationPath(path),
                        key: nil,
                        display: "… \(array.count - index) more",
                        kind: .truncated,
                        isTruncationMarker: true
                    ))
                    break
                }
                children.append(build(
                    element,
                    key: "[\(index)]",
                    path: "\(path)[\(index)]",
                    depth: depth + 1,
                    count: &count
                ))
            }
            return Node(id: path, key: key, display: "[\(array.count)]", kind: .array, children: children)

        case is NSNull:
            return Node(id: path, key: key, display: "null", kind: .null)

        case let number as NSNumber:
            // JSON true/false arrive as CFBoolean-backed NSNumbers; distinguish
            // them from numeric NSNumbers by CoreFoundation type id.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return Node(id: path, key: key, display: number.boolValue ? "true" : "false", kind: .bool)
            }
            return Node(id: path, key: key, display: number.stringValue, kind: .number)

        case let string as String:
            return Node(id: path, key: key, display: string, kind: .string)

        default:
            return Node(id: path, key: key, display: String(describing: data), kind: .string)
        }
    }
}

/// What a JSON document renders as. Deserialization plus tree building is the
/// expensive part of the preview, so it is produced once per content identity
/// rather than on every SwiftUI body evaluation.
enum JsonPreviewOutcome: Sendable {
    case tree(root: JsonTree.Node, truncated: Bool)
    case invalid(message: String)

    nonisolated static func make(_ text: String) -> JsonPreviewOutcome {
        guard let data = text.data(using: .utf8) else {
            return .invalid(message: "File is not valid UTF-8 text.")
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let root = JsonTree.build(object)
            return .tree(root: root, truncated: root.containsTruncation)
        } catch {
            return .invalid(message: error.localizedDescription)
        }
    }
}

/// A collapsible JSON tree. Valid JSON renders as indented `key: value` rows
/// with DisclosureGroups for objects/arrays; invalid JSON shows the parse error
/// above the raw text so the preview is never blank.
struct JsonPreview: View {
    let text: String
    let identity: PreviewParseIdentity

    @State private var cache = PreviewParseCache<JsonPreviewOutcome>()
    @State private var outcome: JsonPreviewOutcome?
    @State private var preparedIdentity: PreviewParseIdentity?

    var body: some View {
        Group {
            if preparedIdentity == identity, let outcome {
                parsedView(outcome)
            } else {
                ProgressView("Preparing JSON…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: identity) {
            let source = text
            let parsed = await cache.value(for: source, parse: JsonPreviewOutcome.make)
            guard !Task.isCancelled else { return }
            outcome = parsed
            preparedIdentity = identity
        }
    }

    @ViewBuilder
    private func parsedView(_ outcome: JsonPreviewOutcome) -> some View {
        switch outcome {
        case let .tree(root, truncated):
            VStack(alignment: .leading, spacing: 0) {
                if truncated { truncationNotice }
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        JsonNodeRow(node: root, depth: 0)
                    }
                    .padding(12)
                }
            }
        case let .invalid(message):
            invalidView(message)
        }
    }

    private var truncationNotice: some View {
        Label(
            "Tree truncated at \(JsonTree.maxDepth) levels / \(JsonTree.maxNodes) nodes.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.14))
    }

    private func invalidView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Invalid JSON — \(message)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(KaisolaStatusTone.needsYou.foregroundColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }
}

/// One row in the JSON tree; recurses through its own type for children (a
/// nominal `View`, so the recursion type-checks without erasure).
private struct JsonNodeRow: View {
    let node: JsonTree.Node
    let depth: Int
    @State private var isExpanded: Bool

    init(node: JsonTree.Node, depth: Int) {
        self.node = node
        self.depth = depth
        // Shallow levels open by default; deeper ones collapse to stay scannable.
        _isExpanded = State(initialValue: depth < 2)
    }

    var body: some View {
        if node.children.isEmpty {
            leafRow
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children) { child in
                    JsonNodeRow(node: child, depth: depth + 1)
                        .padding(.leading, 12)
                }
            } label: {
                containerLabel
            }
            .font(.system(size: 12, design: .monospaced))
        }
    }

    private var leafRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let key = node.key {
                Text(key).foregroundStyle(.secondary)
                Text(":").foregroundStyle(.tertiary)
            }
            Text(scalarText)
                .foregroundStyle(scalarColor)
                .textSelection(.enabled)
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private var containerLabel: some View {
        HStack(spacing: 4) {
            if let key = node.key {
                Text(key).foregroundStyle(.secondary)
                Text(":").foregroundStyle(.tertiary)
            }
            Text(node.display).foregroundStyle(.tertiary)
        }
    }

    private var scalarText: String {
        switch node.kind {
        case .string: "\"\(node.display)\""
        default: node.display
        }
    }

    private var scalarColor: Color {
        switch node.kind {
        case .string: .green
        case .number: .blue
        case .bool: .purple
        case .null: .secondary
        case .truncated: .secondary
        case .object, .array: .primary
        }
    }
}

// MARK: - HTML

/// Distinguishes a static HTML document from a JavaScript-only app shell. The
/// preview keeps project scripts off by default, but an empty app shell should
/// explain that choice instead of presenting a mysterious blank pane.
enum HTMLPreviewReadiness {
    nonisolated static func requiresJavaScriptPrompt(_ source: String) -> Bool {
        guard contains(source, pattern: #"<script\b"#) else { return false }

        let body = firstCapture(
            in: source,
            pattern: #"<body\b[^>]*>([\s\S]*?)</body>"#
        ) ?? source
        let withoutExecutableBlocks = replacing(
            body,
            pattern: #"<(script|style|template)\b[^>]*>[\s\S]*?</\1>"#,
            with: ""
        )
        let hasStaticVisual = contains(
            withoutExecutableBlocks,
            pattern: #"<(img|svg|video|audio|iframe|object|embed)\b"#
        )
        let withoutComments = replacing(
            withoutExecutableBlocks,
            pattern: #"<!--[\s\S]*?-->"#,
            with: ""
        )
        let visibleText = replacing(withoutComments, pattern: #"<[^>]+>"#, with: "")
            .replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&#160;", with: " ", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return visibleText.isEmpty && !hasStaticVisual
    }

    private nonisolated static func contains(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private nonisolated static func firstCapture(in value: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..., in: value)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private nonisolated static func replacing(
        _ value: String,
        pattern: String,
        with replacement: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return value
        }
        return expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement
        )
    }
}

private enum HTMLPreviewLoadState: Equatable {
    case loading
    case ready
    case failed(String)
}

/// Renders a local `.html`/`.htm` file in an ephemeral WKWebView. Project-local
/// assets work by default, while project JavaScript requires an explicit opt-in
/// from the preview menu. Top-level navigation remains confined to the project.
/// Explicit external links are handed to the system browser. This is embedded
/// in `FilePreviewView`, which supplies the outer file chrome.
struct HtmlFilePreview: View {
    let fileURL: URL
    let readAccessRoot: URL?
    let source: String
    let identity: PreviewParseIdentity
    let zoom: CGFloat
    let contentRevision: Int

    @State private var readinessCache = PreviewParseCache<Bool>()
    @State private var requiresJavaScriptPrompt = false
    @State private var preparedIdentity: PreviewParseIdentity?
    @State private var reloadToken = 0
    @State private var allowsJavaScript = false
    @State private var loadState: HTMLPreviewLoadState = .loading

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ConfinedFileWebView(
                fileURL: fileURL,
                readAccessRoot: readAccessRoot,
                allowsJavaScript: allowsJavaScript,
                reloadToken: reloadToken &+ contentRevision,
                zoom: zoom,
                loadState: $loadState
            )
            .id("\(fileURL.path)|js:\(allowsJavaScript)")

            if !requiresJavaScriptPrompt {
                switch loadState {
                case .loading:
                    ProgressView("Rendering HTML…")
                        .controlSize(.small)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(message):
                    ContentUnavailableView {
                        Label("Could not render HTML", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Open in Browser") { NSWorkspace.shared.open(fileURL) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                case .ready:
                    EmptyView()
                }
            }

            if !allowsJavaScript, requiresJavaScriptPrompt {
                VStack(spacing: 10) {
                    Image(systemName: "curlybraces.square")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text("This page needs JavaScript")
                        .font(.headline)
                    Text("Project scripts stay off until you allow them for this preview.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                    HStack(spacing: 8) {
                        Button("Allow JavaScript") { allowsJavaScript = true }
                            .buttonStyle(.borderedProminent)
                        Button("Open in Browser") { NSWorkspace.shared.open(fileURL) }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
            }

            Menu {
                Toggle("Allow project JavaScript", isOn: $allowsJavaScript)
                Button("Reload") { reloadToken &+= 1 }
                Divider()
                Button("Open in Browser") { NSWorkspace.shared.open(fileURL) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .frame(width: 27, height: 22)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 0.7))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("HTML preview options")
            .padding(8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Approval is deliberately one-file-at-a-time. Navigating from a
        // trusted document must never silently grant scripts to the next file.
        .onChange(of: fileURL) { _, _ in allowsJavaScript = false }
        .overlay {
            if preparedIdentity != identity {
                ZStack {
                    Color(nsColor: .textBackgroundColor)
                    ProgressView("Preparing HTML…")
                        .controlSize(.small)
                }
            }
        }
        .task(id: identity) {
            let html = source
            let readiness = await readinessCache.value(
                for: html,
                parse: HTMLPreviewReadiness.requiresJavaScriptPrompt
            )
            guard !Task.isCancelled else { return }
            requiresJavaScriptPrompt = readiness
            preparedIdentity = identity
        }
    }
}

/// A WKWebView with a non-persistent data store and project-confined file
/// access. JavaScript follows the visible preview toggle. Explicit off-scope
/// top-level links open in the system browser; other off-scope navigations are
/// dropped.
private struct ConfinedFileWebView: NSViewRepresentable {
    let fileURL: URL
    let readAccessRoot: URL?
    let allowsJavaScript: Bool
    let reloadToken: Int
    let zoom: CGFloat
    @Binding var loadState: HTMLPreviewLoadState

    func makeCoordinator() -> Coordinator {
        Coordinator(loadState: $loadState)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Ephemeral, and SHARED with the browser card: same trust class, and
        // one store gives the content surfaces shared process affinity
        // instead of isolated ephemeral state per view (spec §2e).
        configuration.websiteDataStore = SharedWebKit.ephemeralContentStore
        // The web view is ephemeral and file-confined. Script execution remains
        // off until the user opts in from the visible preview menu.
        let pagePreferences = WKWebpagePreferences()
        pagePreferences.allowsContentJavaScript = allowsJavaScript
        configuration.defaultWebpagePreferences = pagePreferences
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.pageZoom = zoom

        let directory = effectiveReadAccessRoot
        let coordinator = context.coordinator
        coordinator.directory = directory
        coordinator.loadedURL = fileURL
        coordinator.reloadToken = reloadToken
        loadState = .loading
        webView.loadFileURL(fileURL, allowingReadAccessTo: directory)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        if abs(webView.pageZoom - zoom) > 0.001 {
            webView.pageZoom = zoom
        }
        // Retargeted at a different file (the pane was reused for another doc).
        if coordinator.loadedURL != fileURL {
            let directory = effectiveReadAccessRoot
            coordinator.directory = directory
            coordinator.loadedURL = fileURL
            loadState = .loading
            webView.loadFileURL(fileURL, allowingReadAccessTo: directory)
        }
        // Header reload button was pressed.
        if coordinator.reloadToken != reloadToken {
            coordinator.reloadToken = reloadToken
            loadState = .loading
            webView.reload()
        }
    }

    private var effectiveReadAccessRoot: URL {
        let fallback = fileURL.deletingLastPathComponent()
        guard let candidate = readAccessRoot?.standardizedFileURL,
              WorkspacePreviewLinkPolicy.isContained(fileURL, in: candidate) else { return fallback }
        return candidate
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var loadState: HTMLPreviewLoadState
        var directory: URL?
        var loadedURL: URL?
        var reloadToken = 0

        init(loadState: Binding<HTMLPreviewLoadState>) {
            _loadState = loadState
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            loadState = .loading
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            loadState = .ready
            if ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1" {
                print("KAISOLA_NATIVE_HTML_PREVIEW=ready")
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            fail(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            fail(NSError(
                domain: "Kaisola.HTMLPreview",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The HTML renderer stopped unexpectedly."]
            ))
        }

        private func fail(_ error: Error) {
            loadState = .failed(error.localizedDescription)
            if ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1" {
                print("KAISOLA_NATIVE_HTML_PREVIEW=failed \(error.localizedDescription)")
            }
        }

        // The closure attributes must match the optional requirement exactly
        // (`@MainActor @Sendable`); otherwise Swift treats this as an unrelated
        // method and WebKit never calls it — silently defeating confinement.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let target = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            // Confine to file:// URLs inside the chosen project read root (this
            // also admits the initial load of the file itself).
            if target.isFileURL,
               let directory,
               WorkspacePreviewLinkPolicy.isContained(target, in: directory) {
                decisionHandler(.allow)
                return
            }
            // Off-scope navigation. Hand ONLY an explicit user click on an
            // http(s) link to the real browser — a meta refresh, a scripted
            // redirect, or a custom-scheme navigation (all `.other`) must never
            // auto-launch an external app just because the file was previewed.
            let isTopLevel = navigationAction.targetFrame?.isMainFrame ?? true
            let scheme = target.scheme?.lowercased()
            if isTopLevel,
               navigationAction.navigationType == .linkActivated,
               scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(target)
            }
            decisionHandler(.cancel)
        }

    }
}
