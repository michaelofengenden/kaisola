import Foundation

/// What a `think`-kind tool call actually is.
///
/// The Claude Code adapter reuses ACP's `think` kind for two very different
/// events: spawning a subagent (the Agent/Task tool — the title is the
/// subagent's job description) and compacting the conversation's context.
/// Neither is a shell command, and rendering them as ordinary tool log lines
/// buried the one row that says "part of this work is running somewhere
/// else". Classification is pure and total over the call alone so it can be
/// tested without a live adapter; a `think` call that matches neither shape
/// still classifies as a subagent, because "delegated cognition" is what the
/// kind means when it is not compaction.
enum AcpDelegatedWork: Equatable, Sendable {
    case subagent(AcpSubagentPhase)
    case compaction

    /// The launch acknowledgement a *background* spawn returns immediately.
    /// Its tool call completes the moment the subagent detaches, so a
    /// completed call with this ack is an agent still working out of sight —
    /// the transcript will never hear back from it in-row, and the chip must
    /// say so rather than claim it finished.
    private static let backgroundLaunchMarkers = [
        "Async agent launched successfully",
        "agent is working in the background",
    ]

    static func classify(_ call: AcpToolCall) -> AcpDelegatedWork? {
        guard call.kind == "think" else { return nil }
        if call.title.caseInsensitiveCompare("Compact conversation") == .orderedSame {
            return .compaction
        }
        switch call.status {
        case .pending, .inProgress:
            return .subagent(.working)
        case .failed:
            return .subagent(.failed)
        case .completed:
            // The launch acknowledgement opens the artifact, so only the
            // head is scanned: a finished foreground report can be tens of
            // kilobytes, and this classifier runs on every streamed chunk of
            // a running turn.
            let backgrounded = call.content.contains { artifact in
                guard case let .text(text) = artifact else { return false }
                let head = text.prefix(400)
                return backgroundLaunchMarkers.contains { head.contains($0) }
            }
            return .subagent(backgrounded ? .backgrounded : .finished)
        }
    }
}

/// A subagent chip's lifecycle, as honestly as the stream lets us know it.
enum AcpSubagentPhase: Equatable, Sendable {
    /// The spawning tool call is still open — a foreground subagent is
    /// working and this row will carry its report when it lands.
    case working
    /// Launched detached; alive somewhere, but this transcript will not be
    /// told when it finishes.
    case backgrounded
    /// The report is in this row's artifacts.
    case finished
    case failed

    var statusWord: String {
        switch self {
        case .working: "working…"
        case .backgrounded: "in background"
        case .finished: "finished"
        case .failed: "failed"
        }
    }

    /// The word to show given whether the turn that spawned this subagent is
    /// still alive.
    ///
    /// `.working` means the spawning tool call is still open — which is only
    /// meaningful while the turn is. Once the turn ends, a call still marked
    /// in-progress is one whose outcome the adapter never sent, and a chip
    /// still saying "working…" is claiming live work inside a finished
    /// conversation. That is the "it says working a bunch of times when the
    /// agent has finished" report (2026-08-28): one stale chip for every
    /// subagent whose completion went unrecorded, all of them still animating
    /// under an answer that already landed.
    ///
    /// The honest word is that nothing came back. It is deliberately not
    /// "finished" — we do not know that it finished, only that this
    /// transcript was never told — and not "failed", which asserts an
    /// outcome just as invented.
    func statusWord(turnIsLive: Bool) -> String {
        guard !turnIsLive else { return statusWord }
        switch self {
        case .working: return "no report"
        // A detached agent outliving its turn is expected rather than
        // anomalous, so it keeps its own past-tense word.
        case .backgrounded: return "delegated"
        case .finished, .failed: return statusWord
        }
    }

    /// Whether the chip may animate. Nothing in a finished turn is live, so a
    /// stale chip must go still as well as change its word — an unreported
    /// subagent that kept shimmering would still read as running.
    func animates(turnIsLive: Bool) -> Bool {
        turnIsLive && self == .working
    }
}

/// The current turn's subagent headcount, for the live status row: while the
/// agent is running, "make sure they're working" should not require scrolling
/// back through the log to find the chips.
struct AcpSubagentSummary: Equatable, Sendable {
    var working = 0
    var backgrounded = 0
    var finished = 0
    var failed = 0

    var total: Int { working + backgrounded + finished + failed }

    /// An agentic turn can run for thousands of rows; the status clause
    /// describes the recent shape of the work, so the walk is bounded rather
    /// than proportional to the turn. Spawns are rare rows — several hundred
    /// of lookback holds every real fan-out seen in practice.
    static let derivationWindow = 300

    /// Counts spawns since the last user message — the turn the status row
    /// describes — looking back at most `derivationWindow` rows. Returns nil
    /// when the window has no subagents, so the status row says nothing
    /// rather than "0 subagents".
    static func derive(rows: [AcpTranscriptRow]) -> AcpSubagentSummary? {
        var summary = AcpSubagentSummary()
        for row in rows.suffix(derivationWindow).reversed() {
            if case .user = row { break }
            guard case let .tool(call) = row,
                  case let .subagent(phase) = AcpDelegatedWork.classify(call) else { continue }
            switch phase {
            case .working: summary.working += 1
            case .backgrounded: summary.backgrounded += 1
            case .finished: summary.finished += 1
            case .failed: summary.failed += 1
            }
        }
        return summary.total == 0 ? nil : summary
    }

    /// One quiet clause for the status row. Leads with what is still moving;
    /// failure is always said, and never inside a sentence that claims the
    /// whole set finished.
    var label: String {
        let noun = total == 1 ? "subagent" : "subagents"
        if working > 0 {
            var text = total == working
                ? "\(total) \(noun) working"
                : "\(total) \(noun), \(working) working"
            if failed > 0 { text += ", \(failed) failed" }
            return text
        }
        if backgrounded > 0 {
            var text = total == backgrounded
                ? "\(total) \(noun) in background"
                : "\(total) \(noun), \(backgrounded) in background"
            if failed > 0 { text += ", \(failed) failed" }
            return text
        }
        if failed == total { return "\(total) \(noun) failed" }
        if failed > 0 { return "\(total) \(noun), \(failed) failed" }
        return "\(total) \(noun) finished"
    }
}

/// When the transcript's tail-follow stays engaged after a user-initiated
/// scroll. One number, pure, so the boundary is a unit test: within this
/// distance of the bottom the user is "at the tail" and streaming keeps
/// pinning; beyond it they have deliberately left, and the transcript must
/// hold still until they return or ask.
enum AcpTranscriptFollowPolicy {
    static let reengageDistance: CGFloat = 32

    static func follows(afterUserScrollDistance distance: CGFloat) -> Bool {
        distance <= reengageDistance
    }
}

/// Reading a detached subagent over the harness's shoulder.
///
/// The stream never reports a backgrounded agent again, but the Claude
/// harness's launch acknowledgement names the transcript file the agent
/// writes as it works ("output_file: …tasks/<id>.output", JSONL). Tailing
/// that file is the one honest window into "is it actually doing something"
/// — so the chip can open a live activity view instead of shrugging.
/// Parsing is pure over bytes and deliberately forgiving: an unrecognised
/// line contributes nothing rather than failing the view.
enum AcpSubagentActivity {
    /// The transcript path named in the spawn's launch acknowledgement.
    static func outputFileURL(from call: AcpToolCall) -> URL? {
        for artifact in call.content {
            guard case let .text(text) = artifact else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("output_file:") else { continue }
                let path = trimmed.dropFirst("output_file:".count)
                    .trimmingCharacters(in: .whitespaces)
                guard path.hasPrefix("/") else { continue }
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Recent actions from the tail of a harness JSONL transcript, newest
    /// last. Each assistant `tool_use` becomes "Name — hint" (description
    /// over command over path over prompt); each assistant text chunk becomes
    /// its first line; a `result` line closes the story.
    static func recentActions(fromTail data: Data, limit: Int = 8) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // The tail read may start mid-line; drop the first fragment.
        if lines.count > 1 { lines.removeFirst() }
        var actions: [String] = []
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)
            ) as? [String: Any] else { continue }
            actions.append(contentsOf: describe(object))
        }
        return actions.suffix(limit)
    }

    private static func describe(_ object: [String: Any]) -> [String] {
        switch object["type"] as? String {
        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { item in
                switch item["type"] as? String {
                case "tool_use":
                    let name = item["name"] as? String ?? "Tool"
                    let input = item["input"] as? [String: Any] ?? [:]
                    let hint = (input["description"] as? String)
                        ?? (input["command"] as? String)
                        ?? (input["file_path"] as? String)
                        ?? (input["prompt"] as? String)
                        ?? (input["query"] as? String)
                    return hint.map { "\(name) — \(snippet($0))" } ?? name
                case "text":
                    return (item["text"] as? String).flatMap { text in
                        let line = snippet(text)
                        return line.isEmpty ? nil : "“\(line)”"
                    }
                default:
                    return nil
                }
            }
        case "result":
            return ["Finished"]
        default:
            return []
        }
    }

    private static func snippet(_ text: String, limit: Int = 90) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }
}
