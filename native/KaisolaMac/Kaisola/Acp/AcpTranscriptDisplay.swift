import Foundation

/// What the transcript actually mounts, derived from the row list.
///
/// The reference surfaces (the Codex app foremost) do not show a log line per
/// tool call: between paragraphs of prose there is one quiet marker per burst
/// of work — "Read files, ran a command" — and the call-by-call detail waits
/// behind a click. This pass folds each maximal run of plain tool calls into
/// one `workRun` item; prose, thoughts, subagent chips, compaction lines,
/// plans, and permission rows keep their own line, because those are the
/// occasional things worth reading in the stream.
///
/// Derivation is pure over the rows so the grouping table is a unit test, and
/// it is recomputed once per content version by the view, never per body
/// evaluation.
enum AcpTranscriptDisplayItem: Equatable, Identifiable {
    case row(AcpTranscriptRow)
    /// A maximal run of collapsed plain tool calls. Identity is the first
    /// call's id, which is stable while the run grows at its tail — so an
    /// expansion the user opened stays open as the turn streams.
    case workRun(id: String, calls: [AcpToolCall])

    var id: String {
        switch self {
        case let .row(row): row.id
        case let .workRun(id, _): "workrun-\(id)"
        }
    }

    var rhythmKind: AcpTranscriptMetrics.RowKind {
        switch self {
        case let .row(row): row.rhythmKind
        case .workRun: .work
        }
    }
}

enum AcpTranscriptDisplay {
    /// A tool call folds into a work run when it is plain work: not a
    /// subagent spawn, not a compaction notice — those rows carry their own
    /// meaning and stay visible.
    static func isCollapsible(_ row: AcpTranscriptRow) -> Bool {
        guard case let .tool(call) = row else { return false }
        return AcpDelegatedWork.classify(call) == nil
    }

    /// Folds rows into display items. While the conversation is running, the
    /// trailing still-open calls (pending / in progress) stay out of the
    /// marker and render as live activity lines: the marker summarises what
    /// happened, and the tail shows what is happening.
    static func items(rows: [AcpTranscriptRow], isRunning: Bool) -> [AcpTranscriptDisplayItem] {
        var items: [AcpTranscriptDisplayItem] = []
        var run: [AcpToolCall] = []

        func flushRun() {
            guard let first = run.first else { return }
            items.append(.workRun(id: first.id, calls: run))
            run = []
        }

        for row in rows {
            if isCollapsible(row), case let .tool(call) = row {
                run.append(call)
            } else {
                flushRun()
                items.append(.row(row))
            }
        }

        if isRunning {
            // Every still-open call in the final run stays visible, in order:
            // parallel calls complete out of order, and a suffix split would
            // fold a still-running call under an earlier completion.
            let live = run.filter { $0.status == .pending || $0.status == .inProgress }
            run.removeAll { $0.status == .pending || $0.status == .inProgress }
            flushRun()
            for call in live {
                items.append(.row(.tool(call)))
            }
        } else {
            flushRun()
        }
        return items
    }

    /// The run item containing a given row, so search navigation can expand
    /// the marker hiding its match before scrolling to it. Accepts either the
    /// call's own id or the row-prefixed form the transcript's ForEach uses.
    static func runID(containing rowID: String, in items: [AcpTranscriptDisplayItem]) -> String? {
        for item in items {
            if case let .workRun(_, calls) = item,
               calls.contains(where: { $0.id == rowID || AcpTranscriptRow.tool($0).id == rowID }) {
                return item.id
            }
        }
        return nil
    }

    /// Which message rows are a turn's final answer. Response chrome (the
    /// Copy response affordance) belongs only to the message after which the
    /// agent stopped talking — the next conversational row is the user's, or
    /// the transcript ends. Interim narration flows as plain prose.
    static func finalResponseMessageIDs(rows: [AcpTranscriptRow]) -> Set<String> {
        var ids: Set<String> = []
        var pendingMessageID: String?
        for row in rows {
            switch row {
            case let .message(id, _):
                pendingMessageID = id
            case .user:
                if let id = pendingMessageID { ids.insert(id) }
                pendingMessageID = nil
            default:
                break
            }
        }
        if let id = pendingMessageID { ids.insert(id) }
        return ids
    }
}

/// The marker line's words: counts by kind, spoken the way the Codex app
/// writes them ("Read 3 files, ran a command"), with failures always said.
struct AcpWorkRunSummary: Equatable {
    var reads = 0
    var edits = 0
    var executes = 0
    var searches = 0
    var fetches = 0
    var others = 0
    var failed = 0

    init(calls: [AcpToolCall]) {
        for call in calls {
            switch call.kind {
            case "read": reads += 1
            case "edit", "delete", "move": edits += 1
            case "execute": executes += 1
            case "search": searches += 1
            case "fetch": fetches += 1
            default: others += 1
            }
            if call.status == .failed { failed += 1 }
        }
    }

    var label: String {
        var clauses: [String] = []
        func clause(_ count: Int, _ singular: String, _ plural: String) {
            guard count > 0 else { return }
            clauses.append(count == 1 ? singular : plural)
        }
        clause(executes, "ran a command", "ran \(executes) commands")
        clause(reads, "read a file", "read \(reads) files")
        clause(edits, "edited a file", "edited \(edits) files")
        clause(searches, "searched once", "searched \(searches) times")
        clause(fetches, "fetched a page", "fetched \(fetches) pages")
        clause(others, "one more step", "\(others) more steps")
        guard var text = clauses.first else { return "Worked" }
        for extra in clauses.dropFirst() { text += ", " + extra }
        // Sentence-case the leading clause only; the rest stay lowercase so
        // the line reads as one sentence.
        text = text.prefix(1).uppercased() + text.dropFirst()
        return text
    }

}
