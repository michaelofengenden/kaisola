import Foundation
import KaisolaCore

struct CompanionTerminalStreamHead: Equatable, Sendable {
    let streamEpoch: String
    let endOffset: Int64
}

/// Converts the already-sanitized local session index into the phone's typed
/// projection. No cwd, file path, prompt, terminal bytes, environment, or
/// credential field exists in this construction path.
enum CompanionProjectionBuilder {
    static let maximumProjects = 128
    static let maximumSessions = 256

    static func build(
        drafts: [RememberedSessionDraft],
        terminalStreams: [String: CompanionTerminalStreamHead] = [:],
        revision: Int,
        nowMilliseconds: Int64
    ) -> CompanionProjection {
        var newestByID: [String: RememberedSessionDraft] = [:]
        for draft in drafts {
            let id = portableID(draft.id, domain: "session", maximum: 240)
            if let current = newestByID[id],
               (current.lastActivityAt ?? current.createdAt ?? 0) >=
                (draft.lastActivityAt ?? draft.createdAt ?? 0) { continue }
            newestByID[id] = draft
        }
        let selected = newestByID.values.sorted {
            let left = $0.lastActivityAt ?? $0.createdAt ?? 0
            let right = $1.lastActivityAt ?? $1.createdAt ?? 0
            return left == right ? $0.id < $1.id : left > right
        }.prefix(maximumSessions)

        let sessions = selected.map { draft -> CompanionSession in
            let terminalStream = draft.kind == .terminal ? terminalStreams[draft.id] : nil
            return CompanionSession(
                id: portableID(draft.id, domain: "session", maximum: 240),
                projectId: portableID(draft.projectID, domain: "project", maximum: 160),
                kind: sessionKind(draft.kind),
                title: portableText(draft.title, maximum: 320, fallback: "Kaisola session"),
                status: status(draft.activity),
                needsYou: draft.activity == .needsAttention,
                unread: draft.activity == .needsAttention,
                updatedAt: boundedTime(draft.lastActivityAt ?? draft.createdAt ?? 0, now: nowMilliseconds),
                completedAt: draft.activity == .ended
                    ? boundedTime(draft.lastActivityAt ?? nowMilliseconds, now: nowMilliseconds)
                    : nil,
                provider: draft.agentID.map {
                    portableText($0, maximum: 160, fallback: "Agent")
                },
                startedAt: draft.createdAt.map { boundedTime($0, now: nowMilliseconds) },
                terminalStreamEpoch: terminalStream.map {
                    portableID($0.streamEpoch, domain: "stream", maximum: 160)
                },
                terminalEndOffset: terminalStream.map {
                    min(max(0, $0.endOffset), 9_007_199_254_740_991)
                }
            )
        }

        var projectNames: [String: String] = [:]
        for draft in selected {
            let id = portableID(draft.projectID, domain: "project", maximum: 160)
            projectNames[id] = portableText(
                draft.projectName,
                maximum: 240,
                fallback: "Kaisola project"
            )
        }
        let sessionsByProject = Dictionary(grouping: sessions, by: \.projectId)
        let projects = projectNames.keys.sorted { left, right in
            let leftName = projectNames[left] ?? left
            let rightName = projectNames[right] ?? right
            let order = leftName.localizedCaseInsensitiveCompare(rightName)
            return order == .orderedSame ? left < right : order == .orderedAscending
        }.prefix(maximumProjects).map { id -> CompanionProject in
            let projectSessions = sessionsByProject[id] ?? []
            return CompanionProject(
                id: id,
                name: projectNames[id] ?? "Kaisola project",
                connection: "live",
                lastContactAt: projectSessions.map(\.updatedAt).max() ?? nowMilliseconds,
                counts: counts(projectSessions)
            )
        }
        let allowedProjects = Set(projects.map(\.id))
        let visibleSessions = sessions.filter { allowedProjects.contains($0.projectId) }
        let attention = visibleSessions.filter(\.needsYou).map { session in
            CompanionAttention(
                id: portableID("attention-\(session.id)", domain: "attention", maximum: 160),
                projectId: session.projectId,
                sessionId: session.id,
                kind: "review",
                title: session.title,
                detail: "This session needs your attention.",
                createdAt: session.updatedAt,
                severity: "info"
            )
        }
        return CompanionProjection(
            projectionKind: "kaisola.companion.projection",
            revision: max(0, revision),
            generatedAt: max(0, nowMilliseconds),
            freshness: "live",
            projects: projects,
            sessions: visibleSessions,
            attention: attention,
            permissions: []
        )
    }

    private static func counts(_ sessions: [CompanionSession]) -> CompanionProjectCounts {
        CompanionProjectCounts(
            running: sessions.filter { $0.status == .running }.count,
            waiting: sessions.filter { $0.status == .waiting }.count,
            done: sessions.filter { $0.status == .done }.count,
            failed: sessions.filter { $0.status == .failed }.count
        )
    }

    private static func sessionKind(_ value: RememberedSessionKind) -> CompanionSessionKind {
        switch value {
        case .terminal: .terminal
        case .agentChat: .agent
        case .mesh: .panel
        }
    }

    private static func status(_ value: RememberedSessionActivity) -> CompanionSessionStatus {
        switch value {
        case .idle: .idle
        case .working: .running
        case .needsAttention: .waiting
        case .ended: .done
        }
    }

    private static func boundedTime(_ value: Int64, now: Int64) -> Int64 {
        min(max(0, value), max(0, now))
    }

    private static func portableID(_ value: String, domain: String, maximum: Int) -> String {
        RememberedSessionCatalogPortable.id(
            value,
            domain: domain,
            maximumUTF8Bytes: maximum
        )
    }

    private static func portableText(_ value: String, maximum: Int, fallback: String) -> String {
        let redacted = redactLocalDetails(value)
        return RememberedSessionCatalogPortable.text(
            redacted,
            maximumUTF8Bytes: maximum,
            fallback: fallback
        )
    }

    /// Display labels are user-controlled and sometimes inherit a shell title.
    /// Keep the useful label but fail closed on local paths and common inline
    /// credential forms before the encrypted phone projection is constructed.
    private static func redactLocalDetails(_ value: String) -> String {
        var result = value
        let replacements: [(String, String)] = [
            (#"(?i)\b(api[_-]?(?:key|token)|access[_-]?token|auth[_-]?token|password|secret)\s*[:=]\s*[^\s,;]+"#, "$1=[redacted]"),
            (#"(?i)\b(?:sk-[A-Za-z0-9_-]{12,}|gh[opsu]_[A-Za-z0-9_]{12,}|xox[abprs]-[A-Za-z0-9-]{12,})\b"#, "[redacted]"),
            (#"(?i)(?:/Users/[^/\s]+|/home/[^/\s]+|[A-Z]:\\Users\\[^\\\s]+)(?:[/\\][^\s,;]*)?"#, "[local path]"),
            (#"(?i)(?:/private/(?:var|tmp)|/var|/tmp)(?:/[^\s,;]*)+"#, "[local path]"),
        ]
        for (pattern, replacement) in replacements {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: replacement
            )
        }
        return result
    }
}

/// Monotonic publication gate. Refresh clocks and per-project contact clocks
/// are transport freshness, not user-visible state, so they never create a
/// projection revision on their own.
final class CompanionProjectionRevisions {
    private var revision = 0
    private var fingerprint = Data()
    private(set) var current: CompanionProjection?

    func next(
        drafts: [RememberedSessionDraft],
        terminalStreams: [String: CompanionTerminalStreamHead] = [:],
        nowMilliseconds: Int64
    ) -> CompanionProjection? {
        var candidate = CompanionProjectionBuilder.build(
            drafts: drafts,
            terminalStreams: terminalStreams,
            revision: revision + 1,
            nowMilliseconds: nowMilliseconds
        )
        let nextFingerprint = Self.meaningfulFingerprint(candidate)
        guard nextFingerprint != fingerprint else { return nil }
        revision += 1
        candidate.revision = revision
        fingerprint = nextFingerprint
        current = candidate
        return candidate
    }

    private static func meaningfulFingerprint(_ projection: CompanionProjection) -> Data {
        var content = projection
        content.revision = 0
        content.generatedAt = 0
        for index in content.projects.indices {
            content.projects[index].lastContactAt = 0
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(content)) ?? Data()
    }
}
