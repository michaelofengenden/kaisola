import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Durable usage rollup stored beside a chat's visible transcript. Keeping the
/// latest context window, peak, turns, and cumulative cost together means a
/// restored ACP card and Settings > Usage agree immediately after relaunch.
struct AcpPersistedUsage: Codable, Equatable, Sendable {
    var title: String
    var agentID: String
    var latestUsed: Int
    var latestMax: Int
    var peakUsed: Int
    var turns: Int
    var costAmount: Double?
    var costCurrency: String?
}

/// Privacy-bounded, deterministic Markdown rendering for a transcript export.
/// Visible user/assistant prose and plans remain Markdown. Hidden reasoning,
/// raw tool results, diffs, terminal output, and attachment payloads never enter
/// the document; their visible summaries or explicit omission markers do.
enum AcpTranscriptMarkdownExport {
    struct Request: Equatable, Sendable {
        var title: String
        var agentID: String
        var agentName: String?
        var modelID: String?
        var exportedAt: Date
    }

    struct Receipt: Equatable, Sendable {
        var rowCount: Int
        var startOrdinal: Int64
        var byteCount: Int
        var includedPendingChanges: Bool
    }

    static func markdown(
        request: Request,
        updatedAt: Date?,
        startOrdinal: Int64,
        rows: [AcpTranscriptRow],
        attachments: [AcpAttachment],
        retentionStatus: AcpTranscriptStore.RetentionStatus
    ) -> String {
        var sections: [String] = []
        sections.append("# \(singleLine(request.title))")
        var metadata = [
            "- Exported: \(timestamp(request.exportedAt))",
            "- Agent: \(agentLabel(request))",
        ]
        if let updatedAt { metadata.insert("- Last updated: \(timestamp(updatedAt))", at: 1) }
        if let modelID = normalized(request.modelID) { metadata.append("- Model: \(singleLine(modelID))") }
        metadata.append("- Stored range starts at ordinal: \(max(0, startOrdinal))")
        sections.append(metadata.joined(separator: "\n"))

        if retentionStatus.isTruncated {
            sections.append(
                "> [Earlier retained history truncated: \(retentionStatus.truncatedRowCount) rows, "
                    + "\(retentionStatus.truncatedByteCount) bytes]"
            )
        } else if startOrdinal > 0 {
            sections.append("> [Earlier transcript rows are outside this retained export range]"
            )
        }

        var hiddenReasoningCount = 0
        for row in rows {
            switch row {
            case let .runProfileAudit(_, profile):
                let model = profile.modelID.map { " · Model: \(singleLine($0))" } ?? ""
                sections.append("## Run profile\n\n\(singleLine(profile.name))\(model)")
            case let .user(_, text, failed):
                let state = failed ? " (send failed)" : ""
                var section = "## User\(state)\n\n\(visibleBody(text))"
                if namesAttachment(in: text) {
                    section += "\n\n> [Attachment payload omitted; the transcript retains filename(s) only]"
                }
                sections.append(section)
            case let .message(_, text):
                sections.append("## Assistant\n\n\(visibleBody(text))")
            case .thought:
                hiddenReasoningCount += 1
            case let .tool(call):
                sections.append(toolSummary(call))
            case let .plan(_, entries):
                sections.append(planSummary(entries))
            case .permissionDecision:
                // Permission decisions are ephemeral UI evidence and are never
                // part of the durable transcript exported to disk.
                break
            }
        }
        if hiddenReasoningCount > 0 {
            sections.append(
                "> [\(hiddenReasoningCount) hidden reasoning "
                    + "\(hiddenReasoningCount == 1 ? "row" : "rows") omitted]"
            )
        }
        if !attachments.isEmpty {
            let markers = attachments.map { attachment -> String in
                switch attachment {
                case let .image(_, mimeType, name):
                    return "- [Binary image omitted: \(singleLine(name)) (\(singleLine(mimeType)))]"
                case let .textFile(_, _, name):
                    return "- [Embedded text attachment omitted: \(singleLine(name))]"
                }
            }
            sections.append("## Attachments\n\n" + markers.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    static func lastAssistantResponse(in rows: [AcpTranscriptRow]) -> String? {
        rows.reversed().compactMap { row -> String? in
            guard case let .message(_, text) = row, !text.isEmpty else { return nil }
            return text
        }.first
    }

    static func suggestedFileName(for title: String) -> String {
        sanitizedStem(title) + "-transcript.md"
    }

    private static func toolSummary(_ call: AcpToolCall) -> String {
        var textCount = 0
        var diffCount = 0
        var terminalCount = 0
        for content in call.content {
            switch content {
            case .text: textCount += 1
            case .diff: diffCount += 1
            case .terminal: terminalCount += 1
            }
        }
        var lines = [
            "## Tool result summary",
            "",
            "- Tool: \(singleLine(call.title))",
            "- Kind: \(singleLine(call.kind))",
            "- Status: \(call.status.rawValue)",
        ]
        let artifacts = [
            countLabel(textCount, singular: "text block", plural: "text blocks"),
            countLabel(diffCount, singular: "diff", plural: "diffs"),
            countLabel(terminalCount, singular: "terminal", plural: "terminals"),
        ].compactMap { $0 }
        if !artifacts.isEmpty {
            lines.append("- Result artifacts omitted: " + artifacts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    private static func planSummary(_ entries: [AcpPlanEntry]) -> String {
        let lines = entries.map { entry in
            let checked = entry.status.lowercased() == "completed" ? "x" : " "
            return "- [\(checked)] \(singleLine(entry.content)) "
                + "(\(singleLine(entry.priority)); \(singleLine(entry.status)))"
        }
        return "## Plan\n\n" + (lines.isEmpty ? "- [No plan entries]" : lines.joined(separator: "\n"))
    }

    private static func visibleBody(_ text: String) -> String {
        text.isEmpty ? "[Empty visible message]" : text
    }

    private static func namesAttachment(in text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            line.hasPrefix("📎 ")
        }
    }

    private static func agentLabel(_ request: Request) -> String {
        let id = singleLine(request.agentID)
        guard let name = normalized(request.agentName) else { return id }
        return "\(singleLine(name)) (\(id))"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func singleLine(_ value: String) -> String {
        let joined = value.split(whereSeparator: \.isNewline).joined(separator: " ")
        let controls = CharacterSet.controlCharacters
        return String(joined.unicodeScalars.filter { !controls.contains($0) })
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func countLabel(_ count: Int, singular: String, plural: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? singular : plural)"
    }

    private static func sanitizedStem(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let stem = title.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let compact = String(stem)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return compact.isEmpty ? "chat" : compact
    }
}

/// Mode-0600, actor-serialized transcript persistence for native ACP cards.
/// Provider `session/resume` restores the agent's internal context; this store
/// restores what the user can see immediately without decoding an unbounded
/// transcript at launch. Rows have stable per-chat ordinals and are read from
/// the tail backwards in bounded pages.
actor AcpTranscriptStore {
    struct RetentionPolicy: Equatable, Sendable {
        var maximumRowCount: Int
        var maximumBytes: Int
        var recentRowCount: Int

        init(maximumRowCount: Int, maximumBytes: Int, recentRowCount: Int) {
            self.maximumRowCount = max(1, maximumRowCount)
            self.maximumBytes = max(1, maximumBytes)
            self.recentRowCount = max(0, min(recentRowCount, self.maximumRowCount))
        }

        /// Disk is deliberately cheap to spend (Michael, 2026-08-26: "it's
        /// totally okay for Kaisola to take up as much disk space as
        /// needed"). The old 32 MiB / 10,000-row cap was sized like a cache
        /// and truncated real working history; the quota is now a
        /// pathological-runaway bound only — 2 GiB and a million rows per
        /// chat, roughly two orders of magnitude past the largest transcript
        /// observed in practice. The eviction machinery and its
        /// evidence-first ordering stay, because a bound you never hit still
        /// needs to behave when something absurd hits it.
        static var production: RetentionPolicy {
            RetentionPolicy(
                maximumRowCount: 1_000_000,
                maximumBytes: 2_048 * 1_048_576,
                recentRowCount: 50_000
            )
        }
    }

    struct RetentionStatus: Equatable, Sendable {
        var truncatedRowCount: Int64
        var truncatedByteCount: Int64

        static var empty: RetentionStatus {
            RetentionStatus(truncatedRowCount: 0, truncatedByteCount: 0)
        }
        var isTruncated: Bool { truncatedRowCount > 0 || truncatedByteCount > 0 }
    }

    /// User-visible state for the coalesced snapshot currently waiting to
    /// reach SQLite. A terminal failure remains published until a successful
    /// explicit retry or deletion proves the in-memory-only copy is no longer
    /// at risk.
    struct PersistenceFailure: Equatable, Sendable {
        var attemptCount: Int
        var maximumAttempts: Int

        var detail: String {
            "Kaisola could not save the latest transcript after \(attemptCount) attempts."
        }

        var guidance: String {
            "Retry after checking available disk space and file access, or export the recovery snapshot before closing this chat."
        }
    }

    enum PersistenceHealth: Equatable, Sendable {
        case healthy
        case retrying(attempt: Int, maximumAttempts: Int)
        case failed(PersistenceFailure)

        var failure: PersistenceFailure? {
            guard case let .failed(failure) = self else { return nil }
            return failure
        }

        var needsAttention: Bool { self != .healthy }
    }

    struct PersistenceHealthUpdate: Equatable, Sendable {
        var chatID: String
        var health: PersistenceHealth
    }

    /// Exact loaded transcript snapshot retained in the failed write queue.
    /// A non-zero start ordinal explicitly discloses that older durable pages
    /// were not loaded when this recovery copy was captured.
    struct RecoverySnapshot: Equatable, Sendable {
        var chatID: String
        var startOrdinal: Int64
        var rows: [AcpTranscriptRow]

        var isCompleteTranscript: Bool { startOrdinal == 0 }
    }

    struct Entry: Codable, Equatable, Sendable {
        var rows: [AcpTranscriptRow]
        var updatedAt: Int64
        var usage: AcpPersistedUsage?
        var draft: String?
        var attachments: [AcpAttachment]
        var sessionID: String?

        init(
            rows: [AcpTranscriptRow],
            updatedAt: Int64,
            usage: AcpPersistedUsage? = nil,
            draft: String? = nil,
            attachments: [AcpAttachment] = [],
            sessionID: String? = nil
        ) {
            self.rows = rows
            self.updatedAt = updatedAt
            self.usage = usage
            self.draft = draft
            self.attachments = attachments
            self.sessionID = sessionID
        }
    }

    struct Page: Equatable, Sendable {
        var rows: [AcpTranscriptRow]
        /// Ordinal of `rows.first`, or the requested boundary for an empty page.
        var startOrdinal: Int64
        /// One past the final ordinal in this page.
        var endOrdinalExclusive: Int64
        /// Exact number of retained rows before this page, independent of any
        /// accidental ordinal gaps in a damaged or hand-edited database.
        var earlierRowCount: Int
        var totalRowCount: Int

        static let empty = Page(
            rows: [],
            startOrdinal: 0,
            endOrdinalExclusive: 0,
            earlierRowCount: 0,
            totalRowCount: 0
        )
    }

    struct Restoration: Equatable, Sendable {
        var page: Page
        var updatedAt: Int64
        var usage: AcpPersistedUsage?
        var draft: String?
        var attachments: [AcpAttachment]
        var sessionID: String?
        var retentionStatus: RetentionStatus = .empty
    }

    /// Why a read produced no transcript when the chat may still have one on
    /// disk. Corrupt and unavailable are deliberately distinct: the first
    /// means stored bytes exist and could not be decoded, the second means the
    /// database itself never answered.
    struct RestorationFailure: Equatable, Sendable {
        enum Fault: Equatable, Sendable {
            case corrupt
            case unavailable
        }

        var fault: Fault
        var detail: String
        var databasePath: String

        /// Shown verbatim by the caller. It never claims history was lost,
        /// because a faulted read leaves the stored rows exactly where they
        /// are and the store refuses further writes for the chat.
        var guidance: String {
            let cause = fault == .corrupt
                ? "This chat's saved history is damaged"
                : "This chat's saved history could not be read"
            return """
            \(cause) (\(detail)). Kaisola kept the stored transcript instead of \
            replacing it, and will not write to this chat until the history reads \
            back. Quit Kaisola and back up \(databasePath) before continuing.
            """
        }
    }

    /// A restoration read's three distinguishable answers. Only `.missing`
    /// means "this chat has nothing stored"; `.failed` means the caller must
    /// not treat the absent rows as an empty history.
    enum RestorationOutcome: Equatable, Sendable {
        case restored(Restoration)
        case missing
        case failed(RestorationFailure)

        var restoration: Restoration? {
            guard case let .restored(restoration) = self else { return nil }
            return restoration
        }

        var failure: RestorationFailure? {
            guard case let .failed(failure) = self else { return nil }
            return failure
        }
    }

    /// Answer to "did the user delete this chat?". The third case exists so a
    /// SQLite failure stays distinguishable from a proven absence of any
    /// deletion record (§4e).
    enum TombstoneState: Equatable, Sendable {
        /// The store proved no deletion record exists.
        case absent
        /// A durable deletion record exists.
        case present
        /// The store could not answer. Treated as neither restorable nor
        /// writable, because the chat may well be deleted.
        case unknown
    }

    struct TombstoneSnapshot: Equatable, Hashable, Sendable {
        var chatID: String
        var generation: Int64
    }

    enum TombstoneSnapshotState: Equatable, Sendable {
        case absent
        case present(TombstoneSnapshot)
        case unknown
    }

    enum StoreError: Error, Equatable, Sendable {
        case database(String)
        /// Stored bytes that exist but cannot be decoded back into a row or a
        /// metadata blob. Separate from `database` so a read can report damage
        /// rather than an unreachable file.
        case corruptRecord(String)
        case corruptLegacyArchive
        case legacyArchiveTooLarge(maxBytes: Int)
        case invalidSnapshot

        /// Plain detail for the callers that surface a failed delete. The
        /// errors are not `LocalizedError`, so a raw `localizedDescription`
        /// would show the caller's generic fallback instead of the cause.
        var message: String {
            switch self {
            case let .database(detail): return detail
            case let .corruptRecord(detail): return detail
            case .corruptLegacyArchive: return "the saved transcript archive could not be read"
            case let .legacyArchiveTooLarge(maxBytes):
                return "the saved transcript archive is larger than \(maxBytes) bytes"
            case .invalidSnapshot: return "the transcript snapshot did not match the stored rows"
            }
        }
    }

    /// The outcome of an explicit transcript deletion. A caller only ever
    /// reports a permanent delete after `removed`; `failed` means the durable
    /// bytes may still be on disk and the removal is worth retrying.
    enum Removal: Equatable, Sendable {
        case removed
        case failed(StoreError)

        var isRemoved: Bool {
            if case .removed = self { return true }
            return false
        }

        var failureMessage: String? {
            if case let .failed(error) = self { return error.message }
            return nil
        }
    }

    enum TombstoneResult: Equatable, Sendable {
        case recorded(TombstoneSnapshot)
        case failed(StoreError)

        var snapshot: TombstoneSnapshot? {
            guard case let .recorded(snapshot) = self else { return nil }
            return snapshot
        }
    }

    /// A Mesh owns several transcript identities, but permanent deletion is
    /// one user action. Recording the whole set in one SQLite transaction
    /// prevents a crash from leaving an unreferenced half of the Mesh writable.
    enum TombstoneBatchResult: Equatable, Sendable {
        case recorded([TombstoneSnapshot])
        case failed(StoreError)

        var snapshots: [TombstoneSnapshot]? {
            guard case let .recorded(snapshots) = self else { return nil }
            return snapshots
        }
    }

    /// Deterministic single-use failure seams for the removal transaction.
    /// Tests inject them through an isolated store instance; production stores
    /// always use the nil default.
    enum RemovalFailurePoint: Equatable, Sendable {
        case open
        case delete
        case commit
    }

    enum TombstoneFailurePoint: Equatable, Sendable {
        case open
        case commit
    }

    /// Disk is deliberately cheap to spend (2026-08-06 spec): retention is
    /// generous, and eviction stays oldest-first purely as a sanity bound.
    static let maximumChatCount = 1_000
    static let maximumPageSize = 500
    static let maximumDraftBytes = 256 * 1_024
    static let maximumAttachmentCount = 8
    static let maximumAttachmentBytes = 20 * 1_048_576
    static let maximumLegacyArchiveBytes = 512 * 1_048_576
    static let maximumPersistenceAttempts = 3
    /// A crashed or suspended writer can delay reclamation only for this
    /// bounded interval. Resuming after expiry is still safe: buffered writes
    /// retain their captured deletion generation and fail closed if it moved.
    static let writerLeaseDurationMilliseconds: Int64 = 5 * 60 * 1_000
    /// Exact deletion watermarks survive one-shot cleanup receipts so a writer
    /// that first appears after deletion cannot acknowledge that same generation
    /// and recreate the chat. Old, fully-deleted identifiers are compacted only
    /// after their writers retire; compaction switches unknown identifiers to an
    /// explicit-creation regime instead of turning absence back into authority.
    static let maximumDeletionWatermarks = 4_096
    /// The workspace archive is itself bounded to 64 projects with at most
    /// 256 live and 256 recently-closed chats in each. Keeping the durable
    /// incarnation registry at that same hard ceiling prevents failed
    /// pre-descriptor creations from growing an authorization log forever.
    static let maximumChatIncarnations = 32_768
    static let live: AcpTranscriptStore = {
        let environment = ProcessInfo.processInfo.environment
        let isXCTest = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        guard isXCTest else {
            return AcpTranscriptStore(
                databaseURL: NativePreviewPaths.agentChatTranscriptDatabase,
                legacyJSONURL: NativePreviewPaths.agentChatTranscriptStore
            )
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-xctest-transcripts-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
            isDirectory: true
        )
        return AcpTranscriptStore(
            databaseURL: directory.appendingPathComponent("transcripts-v2.sqlite3"),
            legacyJSONURL: directory.appendingPathComponent("transcripts-v1.json")
        )
    }()

    private struct LegacyEntry: Decodable {
        var rows: [AcpTranscriptRow]
        var updatedAt: Int64
        var usage: AcpPersistedUsage?
    }

    private struct LegacyPayload: Decodable {
        var entries: [String: LegacyEntry]
    }

    private struct RowWrite: Sendable {
        var rows: [AcpTranscriptRow]
        var startOrdinal: Int64
    }

    private enum FieldChange<Value: Sendable>: Sendable {
        case unchanged
        case set(Value?)
    }

    private struct PendingWrite: Sendable {
        var rows: RowWrite?
        var usage: FieldChange<AcpPersistedUsage> = .unchanged
        var draft: FieldChange<String> = .unchanged
        var attachments: FieldChange<[AcpAttachment]> = .unchanged
        var sessionID: FieldChange<String> = .unchanged
        var updatedAt: Int64
        var writerGeneration: Int64
        /// Immutable identity captured when this store actor joined the chat.
        /// A later delete-and-reuse of the same string has a different token.
        var incarnationGeneration: Int64?
        var heldContinuousFence: Bool

        init(
            updatedAt: Int64,
            writerGeneration: Int64,
            incarnationGeneration: Int64?,
            heldContinuousFence: Bool
        ) {
            self.updatedAt = updatedAt
            self.writerGeneration = writerGeneration
            self.incarnationGeneration = incarnationGeneration
            self.heldContinuousFence = heldContinuousFence
        }
    }

    private struct StoredMetadata: Sendable {
        var updatedAt: Int64
        var usage: AcpPersistedUsage?
        var draft: String?
        var attachments: [AcpAttachment]
        var sessionID: String?
        var retentionStatus: RetentionStatus
    }

    private struct RetentionCandidate: Sendable {
        var ordinal: Int64
        var byteCount: Int
        var isPinnedEvidence: Bool
        /// Pending candidates are measured before insertion, so a pathological
        /// snapshot never grows SQLite past the logical quota even briefly.
        var isPending: Bool
    }

    /// SQLite exposes its connection as an `OpaquePointer`, which older Swift 6
    /// region-based isolation checking cannot safely follow through our nested,
    /// synchronous transaction closures. Keep the pointer in one explicitly
    /// owned, unchecked-sendable box. The box never leaves this actor and every
    /// database operation remains actor-serialized; the annotation only makes
    /// that lifetime and synchronization boundary visible to the compiler.
    private final class SQLiteHandle: @unchecked Sendable {
        let pointer: OpaquePointer

        init(_ pointer: OpaquePointer) { self.pointer = pointer }

        deinit { sqlite3_close_v2(pointer) }
    }

    nonisolated let databaseURL: URL
    nonisolated let legacyJSONURL: URL?

    private var databaseHandle: SQLiteHandle?
    /// Chats whose last read faulted. A faulted read hands the caller an empty
    /// transcript; writing that back would delete the rows we could not read
    /// and overwrite metadata we never saw, so every write for the chat is
    /// refused until one of its reads succeeds or it is explicitly removed.
    private var unreadableChatIDs: Set<String> = []
    /// A quota scan is required once per chat per actor lifetime, then writes
    /// enforce the policy as part of their existing transaction. Avoid making
    /// every top-edge page read perform an empty FULL-synchronous commit.
    private var retentionCheckedChatIDs: Set<String> = []
    private var pending: [String: PendingWrite] = [:]
    private var flushTask: Task<Void, Never>?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let writerID: String
    private let schedulesAutomaticFlush: Bool
    private let retentionPolicy: RetentionPolicy
    private var writerGeneration: Int64?
    /// Per-actor immutable bindings prevent a window that survived deletion
    /// from adopting a later intentional reuse merely because the id matches.
    private var boundChatIncarnations: [String: Int64] = [:]
    /// Once a caller explicitly asks to create/bind an incarnation, a failed
    /// attempt must not fall back to legacy implicit-write compatibility.
    private var explicitlyRejectedChatIDs: Set<String> = []
    private var writerLeaseExpiresAt: Int64 = 0
    private var injectedRemovalFailure: RemovalFailurePoint?
    private var injectedTombstoneFailure: TombstoneFailurePoint?
    private var injectedFlushFailureCount: Int
    private var persistenceAttempts: [String: Int] = [:]
    private var persistenceHealthByChatID: [String: PersistenceHealth] = [:]
    private var persistenceHealthContinuations: [
        UUID: AsyncStream<PersistenceHealthUpdate>.Continuation
    ] = [:]

    /// Compatibility initializer: callers hand us the v1 JSON path and the v2
    /// database is created beside it. The JSON remains untouched after a
    /// successful migration so rollback and manual recovery retain the source.
    init(fileURL: URL) {
        let legacy = fileURL.standardizedFileURL
        self.databaseURL = legacy.deletingPathExtension().appendingPathExtension("sqlite3")
        self.legacyJSONURL = legacy
        self.writerID = UUID().uuidString
        self.schedulesAutomaticFlush = true
        self.retentionPolicy = .production
        self.injectedRemovalFailure = nil
        self.injectedTombstoneFailure = nil
        self.injectedFlushFailureCount = 0
    }

    init(
        databaseURL: URL,
        legacyJSONURL: URL? = nil,
        writerID: String = UUID().uuidString,
        schedulesAutomaticFlush: Bool = true,
        injectedRemovalFailure: RemovalFailurePoint? = nil,
        injectedTombstoneFailure: TombstoneFailurePoint? = nil,
        injectedFlushFailureCount: Int = 0,
        retentionPolicy: RetentionPolicy = .production
    ) {
        self.databaseURL = databaseURL.standardizedFileURL
        self.legacyJSONURL = legacyJSONURL?.standardizedFileURL
        self.writerID = writerID
        self.schedulesAutomaticFlush = schedulesAutomaticFlush
        self.retentionPolicy = retentionPolicy
        self.injectedRemovalFailure = injectedRemovalFailure
        self.injectedTombstoneFailure = injectedTombstoneFailure
        self.injectedFlushFailureCount = max(0, injectedFlushFailureCount)
    }

    /// Explicit full-history compatibility read. Product restoration uses
    /// `restoration(for:tailLimit:)`; this API is reserved for bounded tests,
    /// export, and diagnostics that intentionally ask for every row.
    func rows(for chatID: String) -> [AcpTranscriptRow] {
        entry(for: chatID)?.rows ?? []
    }

    func entry(for chatID: String) -> Entry? {
        guard Self.validChatID(chatID) else { return nil }
        flush()
        do {
            let database = try openDatabase()
            try ensureRetentionPolicyApplied(chatID: chatID, database: database)
            guard let metadata = try readMetadata(chatID: chatID, database: database) else {
                unreadableChatIDs.remove(chatID)
                return nil
            }
            let allRows = try readAllRows(chatID: chatID, database: database)
            unreadableChatIDs.remove(chatID)
            return Entry(
                rows: allRows,
                updatedAt: metadata.updatedAt,
                usage: metadata.usage,
                draft: metadata.draft,
                attachments: metadata.attachments,
                sessionID: metadata.sessionID
            )
        } catch {
            unreadableChatIDs.insert(chatID)
            return nil
        }
    }

    /// Restore only the newest bounded page plus compact per-chat metadata.
    /// The returned `earlierRowCount` drives repeated top-edge reads without
    /// materializing the rest of the session in memory.
    ///
    /// The outcome is typed on purpose: a chat with no stored transcript and a
    /// chat whose transcript is locked or damaged used to look identical, and
    /// the caller would restore the second as an empty history that the next
    /// save then wrote over.
    func restoration(for chatID: String, tailLimit: Int) -> RestorationOutcome {
        guard Self.validChatID(chatID) else { return .missing }
        flush()
        do {
            let database = try openDatabase()
            try ensureRetentionPolicyApplied(chatID: chatID, database: database)
            guard let metadata = try readMetadata(chatID: chatID, database: database) else {
                unreadableChatIDs.remove(chatID)
                return .missing
            }
            let page = try readTailPage(
                chatID: chatID,
                limit: Self.boundedPageLimit(tailLimit),
                database: database
            )
            unreadableChatIDs.remove(chatID)
            return .restored(Restoration(
                page: page,
                updatedAt: metadata.updatedAt,
                usage: metadata.usage,
                draft: metadata.draft,
                attachments: metadata.attachments,
                sessionID: metadata.sessionID,
                retentionStatus: metadata.retentionStatus
            ))
        } catch {
            unreadableChatIDs.insert(chatID)
            return .failed(Self.failure(for: error, databasePath: databaseURL.path))
        }
    }

    /// True while this chat's stored state could not be read back, which is
    /// also exactly while its writes are refused.
    func hasUnreadableHistory(chatID: String) -> Bool {
        unreadableChatIDs.contains(chatID)
    }

    func persistenceHealth(for chatID: String) -> PersistenceHealth {
        persistenceHealthByChatID[chatID] ?? .healthy
    }

    func persistenceHealthUpdates() -> AsyncStream<PersistenceHealthUpdate> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PersistenceHealthUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        persistenceHealthContinuations[id] = continuation
        for chatID in persistenceHealthByChatID.keys.sorted() {
            guard let health = persistenceHealthByChatID[chatID] else { continue }
            continuation.yield(PersistenceHealthUpdate(chatID: chatID, health: health))
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removePersistenceHealthContinuation(id) }
        }
        return stream
    }

    func recoverySnapshot(for chatID: String) -> RecoverySnapshot? {
        guard let rowWrite = pending[chatID]?.rows else { return nil }
        return RecoverySnapshot(
            chatID: chatID,
            startOrdinal: rowWrite.startOrdinal,
            rows: rowWrite.rows
        )
    }

    /// Write a complete retained transcript straight from this store actor to
    /// disk. The UI receives only the small receipt, so a paged chat never has
    /// to materialize its older rows on the main actor. A terminal persistence
    /// failure keeps its exact queued snapshot authoritative: durable rows
    /// before that snapshot are joined with the pending tail for recovery.
    func exportMarkdown(
        for chatID: String,
        request: AcpTranscriptMarkdownExport.Request,
        to destination: URL
    ) throws -> AcpTranscriptMarkdownExport.Receipt {
        guard Self.validChatID(chatID), destination.isFileURL else {
            throw StoreError.database("Transcript export destination is invalid")
        }
        let pendingWrite = pending[chatID]
        let database = try openDatabase()
        try ensureRetentionPolicyApplied(chatID: chatID, database: database)
        let storedMetadata = try readMetadata(chatID: chatID, database: database)
        var ordinalRows = try readAllOrdinalRows(chatID: chatID, database: database)

        if let rowWrite = pendingWrite?.rows {
            ordinalRows.removeAll { $0.ordinal >= rowWrite.startOrdinal }
            ordinalRows.append(contentsOf: rowWrite.rows.enumerated().map { offset, row in
                (ordinal: rowWrite.startOrdinal + Int64(offset), row: row)
            })
        }
        guard storedMetadata != nil || pendingWrite != nil || !ordinalRows.isEmpty else {
            throw StoreError.database("No transcript is available to export")
        }

        let attachments: [AcpAttachment]
        switch pendingWrite?.attachments {
        case let .set(value): attachments = value ?? []
        case .unchanged, nil: attachments = storedMetadata?.attachments ?? []
        }
        let updatedAtMilliseconds = max(
            storedMetadata?.updatedAt ?? 0,
            pendingWrite?.updatedAt ?? 0
        )
        let markdown = AcpTranscriptMarkdownExport.markdown(
            request: request,
            updatedAt: updatedAtMilliseconds > 0
                ? Date(timeIntervalSince1970: Double(updatedAtMilliseconds) / 1_000)
                : nil,
            startOrdinal: ordinalRows.first?.ordinal ?? pendingWrite?.rows?.startOrdinal ?? 0,
            rows: ordinalRows.map(\.row),
            attachments: attachments,
            retentionStatus: storedMetadata?.retentionStatus ?? .empty
        )
        let data = Data(markdown.utf8)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
        return AcpTranscriptMarkdownExport.Receipt(
            rowCount: ordinalRows.count,
            startOrdinal: ordinalRows.first?.ordinal ?? pendingWrite?.rows?.startOrdinal ?? 0,
            byteCount: data.count,
            includedPendingChanges: pendingWrite != nil
        )
    }

    /// The warning is the circuit breaker: ordinary stream updates and
    /// lifecycle flushes cannot silently become attempt four. Only the user's
    /// Retry action resets the count and immediately makes one new attempt.
    func retryPersistence(chatID: String) {
        guard pending[chatID] != nil else {
            clearPersistenceHealth(chatID: chatID)
            return
        }
        persistenceAttempts[chatID] = 0
        flush(chatIDs: [chatID])
    }

    private func removePersistenceHealthContinuation(_ id: UUID) {
        persistenceHealthContinuations.removeValue(forKey: id)
    }

    private func publishPersistenceHealth(
        _ health: PersistenceHealth,
        chatID: String
    ) {
        if health == .healthy {
            persistenceHealthByChatID.removeValue(forKey: chatID)
        } else {
            persistenceHealthByChatID[chatID] = health
        }
        let update = PersistenceHealthUpdate(chatID: chatID, health: health)
        for continuation in persistenceHealthContinuations.values {
            continuation.yield(update)
        }
    }

    private func clearPersistenceHealth(chatID: String) {
        let hadState = persistenceAttempts.removeValue(forKey: chatID) != nil
            || persistenceHealthByChatID[chatID] != nil
        guard hadState else { return }
        publishPersistenceHealth(.healthy, chatID: chatID)
    }

    private static func failure(for error: Error, databasePath: String) -> RestorationFailure {
        let fault: RestorationFailure.Fault
        let detail: String
        switch error as? StoreError {
        case let .corruptRecord(message):
            fault = .corrupt
            detail = message
        case .corruptLegacyArchive:
            fault = .corrupt
            detail = "the imported v1 archive could not be decoded"
        case let .legacyArchiveTooLarge(maxBytes):
            fault = .unavailable
            detail = "the v1 archive is larger than \(maxBytes) bytes"
        case let .database(message):
            fault = .unavailable
            detail = message
        case .invalidSnapshot:
            fault = .corrupt
            detail = "the stored row ordinals are inconsistent"
        case .none:
            fault = .unavailable
            detail = (error as NSError).localizedDescription
        }
        return RestorationFailure(fault: fault, detail: detail, databasePath: databasePath)
    }

    /// Read the bounded page immediately before an already loaded ordinal.
    func page(for chatID: String, beforeOrdinal: Int64, limit: Int) -> Page? {
        guard Self.validChatID(chatID), beforeOrdinal >= 0,
              let database = try? openDatabase() else { return nil }
        do { try ensureRetentionPolicyApplied(chatID: chatID, database: database) }
        catch {
            return nil
        }
        return try? readPage(
            chatID: chatID,
            beforeOrdinal: beforeOrdinal,
            limit: Self.boundedPageLimit(limit),
            database: database
        )
    }

    /// Coalesce streaming chunks into one SQLite transaction. `startOrdinal`
    /// identifies the first loaded row, allowing a restored tail to update
    /// without deleting retained pages that have not been read this launch.
    func scheduleSave(
        _ rows: [AcpTranscriptRow],
        for chatID: String,
        startOrdinal: Int64 = 0,
        now: Int64? = nil
    ) {
        guard Self.validChatID(chatID), startOrdinal >= 0,
              startOrdinal <= Int64.max - Int64(rows.count),
              !unreadableChatIDs.contains(chatID) else { return }
        let timestamp = Self.timestamp(now)
        guard let fence = captureWriterFence(chatID: chatID) else { return }
        var write = pending[chatID] ?? PendingWrite(
            updatedAt: timestamp,
            writerGeneration: fence.generation,
            incarnationGeneration: fence.incarnationGeneration,
            heldContinuousFence: fence.continuous
        )
        write.rows = RowWrite(rows: rows, startOrdinal: startOrdinal)
        write.updatedAt = max(write.updatedAt, timestamp)
        write.writerGeneration = min(write.writerGeneration, fence.generation)
        guard write.incarnationGeneration == fence.incarnationGeneration else { return }
        write.heldContinuousFence = write.heldContinuousFence && fence.continuous
        pending[chatID] = write
        scheduleFlush()
    }

    func scheduleUsage(_ usage: AcpPersistedUsage, for chatID: String, now: Int64? = nil) {
        guard Self.validChatID(chatID), !unreadableChatIDs.contains(chatID) else { return }
        let timestamp = Self.timestamp(now)
        guard let fence = captureWriterFence(chatID: chatID) else { return }
        var write = pending[chatID] ?? PendingWrite(
            updatedAt: timestamp,
            writerGeneration: fence.generation,
            incarnationGeneration: fence.incarnationGeneration,
            heldContinuousFence: fence.continuous
        )
        write.usage = .set(usage)
        write.updatedAt = max(write.updatedAt, timestamp)
        write.writerGeneration = min(write.writerGeneration, fence.generation)
        guard write.incarnationGeneration == fence.incarnationGeneration else { return }
        write.heldContinuousFence = write.heldContinuousFence && fence.continuous
        pending[chatID] = write
        scheduleFlush()
    }

    func scheduleDraft(_ draft: String, for chatID: String, now: Int64? = nil) {
        guard Self.validChatID(chatID), !unreadableChatIDs.contains(chatID),
              draft.lengthOfBytes(using: .utf8) <= Self.maximumDraftBytes else { return }
        let timestamp = Self.timestamp(now)
        guard let fence = captureWriterFence(chatID: chatID) else { return }
        var write = pending[chatID] ?? PendingWrite(
            updatedAt: timestamp,
            writerGeneration: fence.generation,
            incarnationGeneration: fence.incarnationGeneration,
            heldContinuousFence: fence.continuous
        )
        write.draft = .set(draft.isEmpty ? nil : draft)
        write.updatedAt = max(write.updatedAt, timestamp)
        write.writerGeneration = min(write.writerGeneration, fence.generation)
        guard write.incarnationGeneration == fence.incarnationGeneration else { return }
        write.heldContinuousFence = write.heldContinuousFence && fence.continuous
        pending[chatID] = write
        scheduleFlush()
    }

    func scheduleAttachments(
        _ attachments: [AcpAttachment],
        for chatID: String,
        now: Int64? = nil
    ) {
        guard Self.validChatID(chatID), !unreadableChatIDs.contains(chatID),
              Self.attachmentsAreBounded(attachments) else { return }
        let timestamp = Self.timestamp(now)
        guard let fence = captureWriterFence(chatID: chatID) else { return }
        var write = pending[chatID] ?? PendingWrite(
            updatedAt: timestamp,
            writerGeneration: fence.generation,
            incarnationGeneration: fence.incarnationGeneration,
            heldContinuousFence: fence.continuous
        )
        write.attachments = .set(attachments.isEmpty ? nil : attachments)
        write.updatedAt = max(write.updatedAt, timestamp)
        write.writerGeneration = min(write.writerGeneration, fence.generation)
        guard write.incarnationGeneration == fence.incarnationGeneration else { return }
        write.heldContinuousFence = write.heldContinuousFence && fence.continuous
        pending[chatID] = write
        scheduleFlush()
    }

    func scheduleSessionID(_ sessionID: String?, for chatID: String, now: Int64? = nil) {
        guard Self.validChatID(chatID), !unreadableChatIDs.contains(chatID) else { return }
        let normalized = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized?.lengthOfBytes(using: .utf8) ?? 0 <= 4_096 else { return }
        let timestamp = Self.timestamp(now)
        guard let fence = captureWriterFence(chatID: chatID) else { return }
        var write = pending[chatID] ?? PendingWrite(
            updatedAt: timestamp,
            writerGeneration: fence.generation,
            incarnationGeneration: fence.incarnationGeneration,
            heldContinuousFence: fence.continuous
        )
        write.sessionID = .set(normalized?.isEmpty == false ? normalized : nil)
        write.updatedAt = max(write.updatedAt, timestamp)
        write.writerGeneration = min(write.writerGeneration, fence.generation)
        guard write.incarnationGeneration == fence.incarnationGeneration else { return }
        write.heldContinuousFence = write.heldContinuousFence && fence.continuous
        pending[chatID] = write
        scheduleFlush()
    }

    func clearUsage() {
        flush()
        for chatID in pending.keys {
            pending[chatID]?.usage = .set(nil)
        }
        guard let database = try? openDatabase() else { return }
        do {
            try transaction(database) {
                try execute("UPDATE chats SET usage_json = NULL", database: database)
                try pruneEmptyChats(database)
                try setMetadataValue("1", for: "v2_has_written", database: database)
            }
        } catch {
            // A failed reset must not mutate the actor's in-memory queue.
        }
    }

    func removeUsage(chatID: String) {
        guard Self.validChatID(chatID) else { return }
        flush()
        pending[chatID]?.usage = .set(nil)
        guard let database = try? openDatabase() else { return }
        do {
            try transaction(database) {
                try withStatement("UPDATE chats SET usage_json = NULL WHERE chat_id = ?", database: database) {
                    try bind(chatID, at: 1, statement: $0, database: database)
                    try stepDone($0, database: database)
                }
                try pruneEmptyChats(database)
                try setMetadataValue("1", for: "v2_has_written", database: database)
            }
        } catch {
            // Usage removal is best-effort and never interrupts a live chat.
        }
    }

    private func scheduleFlush() {
        guard schedulesAutomaticFlush,
              pending.keys.contains(where: {
                  persistenceAttempts[$0, default: 0] < Self.maximumPersistenceAttempts
              }) else { return }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Capture the generation under a durable lease before any snapshot enters
    /// the in-memory coalescing queue. If the database cannot establish that
    /// fence, generation -1 makes the eventual flush fail closed.
    private func captureWriterFence(
        chatID: String
    ) -> (generation: Int64, incarnationGeneration: Int64?, continuous: Bool)? {
        guard !explicitlyRejectedChatIDs.contains(chatID) else { return nil }
        let now = Self.timestamp(nil)
        do {
            let database = try openDatabase()
            var generation: Int64 = -1
            var incarnationGeneration: Int64?
            var wasLive = false
            var authorized = false
            try transaction(database) {
                let current = try currentDeletionGeneration(database)
                generation = writerGeneration ?? current
                wasLive = try writerLeaseIsLive(now: now, database: database)
                let watermark = try deletionWatermarkGeneration(
                    chatID: chatID,
                    database: database
                )
                let durableIncarnation = try chatIncarnationGeneration(
                    chatID: chatID,
                    database: database
                )
                if let bound = boundChatIncarnations[chatID] {
                    guard durableIncarnation == bound else { return }
                    incarnationGeneration = bound
                } else if durableIncarnation != nil {
                    // A durable identity is not permission for an arbitrary
                    // actor to adopt it. Product creation and restoration bind
                    // this actor explicitly through begin/establish first.
                    return
                } else {
                    guard try !requiresExplicitChatCreation(database) else { return }
                }
                if let incarnationGeneration {
                    guard watermark.map({ incarnationGeneration > $0 }) ?? true else { return }
                } else {
                    guard watermark.map({ generation > $0 }) ?? true else { return }
                }
                let acknowledgedGeneration = pending.values.reduce(generation) {
                    min($0, $1.writerGeneration)
                }
                try upsertWriterLease(
                    acknowledgedGeneration: acknowledgedGeneration,
                    now: now,
                    database: database
                )
                writerLeaseExpiresAt = Self.writerLeaseDeadline(after: now)
                // A newly registered writer starts a continuous fence only
                // when no deletion generation elapsed while it was absent.
                if generation == current { wasLive = true }
                authorized = true
            }
            guard authorized else { return nil }
            writerGeneration = generation
            return (generation, incarnationGeneration, wasLive)
        } catch {
            return nil
        }
    }

    /// Atomically establish the durable identity of an intentionally new chat.
    /// Normal product calls supply a freshly generated UUID; the same operation
    /// is the only supported way to deliberately reuse an id after deletion,
    /// in which case its generation is strictly advanced. This registry row is
    /// the first persisted chat write, not a token consumed by a later flush,
    /// so a crash cannot separate authorization from the authorized identity.
    func beginNewChatID(_ chatID: String) -> Bool {
        guard Self.validChatID(chatID) else { return false }
        explicitlyRejectedChatIDs.insert(chatID)
        do {
            let database = try openDatabase()
            var generation: Int64 = -1
            try transaction(database) {
                guard try !hasTombstone(chatID: chatID, database: database) else {
                    throw StoreError.database(
                        "a transcript deletion is still being reconciled for this chat"
                    )
                }
                let current = try currentDeletionGeneration(database)
                let existingIncarnation = try chatIncarnationGeneration(
                    chatID: chatID,
                    database: database
                )
                if let bound = boundChatIncarnations[chatID],
                   let existingIncarnation,
                   bound != existingIncarnation {
                    throw StoreError.database(
                        "this transcript writer belongs to an older chat incarnation"
                    )
                }
                if let existing = existingIncarnation {
                    guard boundChatIncarnations[chatID] == existing else {
                        throw StoreError.database(
                            "a different transcript actor already owns this chat incarnation"
                        )
                    }
                    generation = existing
                } else if let watermark = try deletionWatermarkGeneration(
                    chatID: chatID,
                    database: database
                ), current <= watermark {
                    generation = try nextDeletionGeneration(database)
                } else if try requiresExplicitChatCreation(database) {
                    generation = try nextDeletionGeneration(database)
                } else {
                    generation = current
                }
                if existingIncarnation == nil {
                    guard try chatIncarnationCount(database) < Self.maximumChatIncarnations else {
                        throw StoreError.database("transcript chat incarnation capacity is exhausted")
                    }
                }
                try withStatement(
                    """
                    INSERT INTO chat_incarnations(chat_id, generation, created_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(chat_id) DO UPDATE SET
                        generation = MAX(chat_incarnations.generation, excluded.generation)
                    """,
                    database: database
                ) {
                    try bind(chatID, at: 1, statement: $0, database: database)
                    try bind(generation, at: 2, statement: $0, database: database)
                    try bind(Self.timestamp(nil), at: 3, statement: $0, database: database)
                    try stepDone($0, database: database)
                }
                try setMetadataValue("1", for: "v2_has_written", database: database)
            }
            if let previous = boundChatIncarnations[chatID], previous != generation {
                pending.removeValue(forKey: chatID)
            }
            boundChatIncarnations[chatID] = generation
            explicitlyRejectedChatIDs.remove(chatID)
            writerGeneration = generation
            return true
        } catch {
            return false
        }
    }

    /// Grandfather a workspace descriptor only before watermark compaction has
    /// ever discarded exact ids. This migrates legitimately old empty chats to
    /// durable incarnation rows; after compaction, an unknown missing id remains
    /// fail-closed and cannot be authorized by a possibly stale descriptor.
    func establishRestorableChatID(_ chatID: String) -> Bool {
        guard Self.validChatID(chatID) else { return false }
        explicitlyRejectedChatIDs.insert(chatID)
        do {
            let database = try openDatabase()
            var established = false
            var establishedGeneration: Int64?
            try transaction(database) {
                if let existing = try chatIncarnationGeneration(
                    chatID: chatID,
                    database: database
                ) {
                    establishedGeneration = existing
                    established = true
                    return
                }
                guard try !requiresExplicitChatCreation(database),
                      try !hasTombstone(chatID: chatID, database: database),
                      try deletionWatermarkGeneration(
                        chatID: chatID,
                        database: database
                      ) == nil else { return }
                guard try chatIncarnationCount(database) < Self.maximumChatIncarnations else {
                    throw StoreError.database("transcript chat incarnation capacity is exhausted")
                }
                let generation = try currentDeletionGeneration(database)
                try withStatement(
                    """
                    INSERT INTO chat_incarnations(chat_id, generation, created_at)
                    VALUES (?, ?, ?)
                    """,
                    database: database
                ) {
                    try bind(chatID, at: 1, statement: $0, database: database)
                    try bind(generation, at: 2, statement: $0, database: database)
                    try bind(Self.timestamp(nil), at: 3, statement: $0, database: database)
                    try stepDone($0, database: database)
                }
                establishedGeneration = generation
                established = true
            }
            if established, let generation = establishedGeneration {
                if let bound = boundChatIncarnations[chatID], bound != generation {
                    return false
                }
                boundChatIncarnations[chatID] = generation
                explicitlyRejectedChatIDs.remove(chatID)
            }
            return established
        } catch {
            return false
        }
    }

    /// Roll back a newly provisioned identity that never acquired transcript
    /// payload or a workspace descriptor (for example, a Mesh column whose
    /// worktree provisioning failed). Exact generation matching means this
    /// actor cannot abandon a later reuse established by another window.
    func abandonNewChatID(_ chatID: String) -> Bool {
        guard Self.validChatID(chatID),
              let generation = boundChatIncarnations[chatID],
              pending[chatID] == nil else { return false }
        do {
            let database = try openDatabase()
            var abandoned = false
            try transaction(database) {
                guard try !hasTombstone(chatID: chatID, database: database),
                      try !chatExists(chatID: chatID, database: database) else { return }
                try withStatement(
                    "DELETE FROM chat_incarnations WHERE chat_id = ? AND generation = ?",
                    database: database
                ) {
                    try bind(chatID, at: 1, statement: $0, database: database)
                    try bind(generation, at: 2, statement: $0, database: database)
                    try stepDone($0, database: database)
                }
                abandoned = sqlite3_changes(database.pointer) == 1
            }
            if abandoned {
                boundChatIncarnations.removeValue(forKey: chatID)
                explicitlyRejectedChatIDs.insert(chatID)
            }
            return abandoned
        } catch {
            return false
        }
    }

    @discardableResult
    func remove(
        chatID: String,
        verifiedDescriptorPruning tombstone: TombstoneSnapshot? = nil
    ) -> Removal {
        guard Self.validChatID(chatID) else {
            return .failed(.database("invalid transcript chat identifier"))
        }
        if let tombstone, tombstone.chatID != chatID {
            return .failed(.database("transcript deletion receipt did not match the chat"))
        }
        let removedPending = pending.removeValue(forKey: chatID)
        do {
            try consumeRemovalFailure(.open)
            let database = try openDatabase()
            try transaction(
                database,
                beforeCommit: { try self.consumeRemovalFailure(.commit) }
            ) {
                // A tombstone begins descriptor-blocked. Only the exact
                // generation returned by tombstone(chatID:) can release that
                // fence after catalog pruning succeeds. A nil receipt still
                // erases transcript bytes, but deliberately retains the
                // tombstone so a stale workspace descriptor cannot restore.
                if let tombstone {
                    try releaseDescriptorFence(tombstone, database: database)
                }
                try consumeRemovalFailure(.delete)
                try withStatement("DELETE FROM chats WHERE chat_id = ?", database: database) {
                    try bind(chatID, at: 1, statement: $0, database: database)
                    try stepDone($0, database: database)
                }
                if pending.isEmpty {
                    try retireWriter(database)
                }
                try expireWriterLeases(now: Self.timestamp(nil), database: database)
                try reclaimEligibleTombstones(database)
                try setMetadataValue("1", for: "v2_has_written", database: database)
            }
            if pending.isEmpty { writerLeaseExpiresAt = 0 }
            // Explicit destruction is the one write an unreadable chat still
            // accepts. End the refusal only after the deletion commits.
            unreadableChatIDs.remove(chatID)
            clearPersistenceHealth(chatID: chatID)
            return .removed
        } catch {
            // Actor serialization means no newer write for this chat can land
            // between removal and restoration. Put back the exact coalesced
            // entry only after every open/DELETE/commit failure path.
            if let removedPending { pending[chatID] = removedPending }
            return .failed(Self.storeError(error))
        }
    }

    // MARK: - Deletion tombstones (closed-stays-closed §4e)

    /// Written FIRST when a chat is deleted, before any in-memory removal, so
    /// every phase after it — and every other window sharing this database —
    /// converges on "gone" even across a crash. Pending content remains
    /// untouched until that transaction commits, and the typed result prevents
    /// callers from reporting success for an intent SQLite did not persist.
    @discardableResult
    func tombstone(chatID: String) -> TombstoneResult {
        switch recordTombstones(chatIDs: [chatID]) {
        case let .recorded(snapshots):
            guard let snapshot = snapshots.first else {
                return .failed(.database("transcript deletion intent was not recorded"))
            }
            return .recorded(snapshot)
        case let .failed(error):
            return .failed(error)
        }
    }

    /// Atomically record every transcript identity owned by one Mesh. The
    /// sorted, deduplicated result gives callers an exact receipt per column;
    /// any invalid member or transaction failure records none of them.
    @discardableResult
    func tombstone(chatIDs: [String]) -> TombstoneBatchResult {
        recordTombstones(chatIDs: chatIDs)
    }

    private func recordTombstones(chatIDs: [String]) -> TombstoneBatchResult {
        let normalizedChatIDs = Array(Set(chatIDs)).sorted()
        guard normalizedChatIDs.count == chatIDs.count,
              normalizedChatIDs.count <= 256,
              normalizedChatIDs.allSatisfy(Self.validChatID) else {
            return .failed(.database("invalid transcript chat identifier"))
        }
        guard !normalizedChatIDs.isEmpty else { return .recorded([]) }
        let deletedChatIDs = Set(normalizedChatIDs)
        let hasOtherPendingWrites = pending.keys.contains {
            !deletedChatIDs.contains($0)
        }
        let now = Self.timestamp(nil)
        var snapshots: [TombstoneSnapshot] = []
        do {
            try consumeTombstoneFailure(.open)
            let database = try openDatabase()
            try transaction(
                database,
                beforeCommit: { try self.consumeTombstoneFailure(.commit) }
            ) {
                try ensureDeletedChatsTable(database)
                for chatID in normalizedChatIDs {
                    let deletionGeneration = try nextDeletionGeneration(database)
                    try withStatement(
                        """
                        INSERT INTO deleted_chats(
                            chat_id, deleted_at, generation, descriptor_reclaim_blocked,
                            external_cleanup_blocked
                        )
                        VALUES (?, ?, ?, 1, 1)
                        ON CONFLICT(chat_id) DO UPDATE SET
                            deleted_at = excluded.deleted_at,
                            generation = excluded.generation,
                            descriptor_reclaim_blocked = 1,
                            external_cleanup_blocked = 1
                        """,
                        database: database
                    ) {
                        try bind(chatID, at: 1, statement: $0, database: database)
                        try bind(now, at: 2, statement: $0, database: database)
                        try bind(deletionGeneration, at: 3, statement: $0, database: database)
                        try stepDone($0, database: database)
                    }
                    try withStatement(
                        "DELETE FROM chat_incarnations WHERE chat_id = ?",
                        database: database
                    ) {
                        try bind(chatID, at: 1, statement: $0, database: database)
                        try stepDone($0, database: database)
                    }
                    try withStatement(
                        """
                        INSERT INTO deletion_watermarks(chat_id, generation, deleted_at)
                        VALUES (?, ?, ?)
                        ON CONFLICT(chat_id) DO UPDATE SET
                            generation = excluded.generation,
                            deleted_at = excluded.deleted_at
                        """,
                        database: database
                    ) {
                        try bind(chatID, at: 1, statement: $0, database: database)
                        try bind(deletionGeneration, at: 2, statement: $0, database: database)
                        try bind(now, at: 3, statement: $0, database: database)
                        try stepDone($0, database: database)
                    }
                    snapshots.append(TombstoneSnapshot(
                        chatID: chatID,
                        generation: deletionGeneration
                    ))
                }
                if hasOtherPendingWrites {
                    try upsertWriterLease(
                        acknowledgedGeneration: snapshots.last?.generation ?? 0,
                        now: now,
                        database: database
                    )
                } else {
                    try retireWriter(database)
                }
            }
            // This is the commit boundary: only now may each target's exact
            // pending entry and immutable incarnation binding disappear.
            for chatID in normalizedChatIDs {
                pending.removeValue(forKey: chatID)
                boundChatIncarnations.removeValue(forKey: chatID)
                explicitlyRejectedChatIDs.insert(chatID)
                unreadableChatIDs.remove(chatID)
                clearPersistenceHealth(chatID: chatID)
            }
            let deletionGeneration = snapshots.last?.generation ?? 0
            writerGeneration = deletionGeneration
            writerLeaseExpiresAt = hasOtherPendingWrites
                ? Self.writerLeaseDeadline(after: now)
                : 0
            for pendingChatID in pending.keys {
                pending[pendingChatID]?.writerGeneration = deletionGeneration
                pending[pendingChatID]?.heldContinuousFence = true
            }
            return .recorded(snapshots)
        } catch {
            return .failed(Self.storeError(error))
        }
    }

    /// Tri-state deletion probe. Restoration and persistence proceed only on
    /// `.absent`, so a lookup the store cannot complete fails closed instead
    /// of authorizing content the user permanently deleted.
    func tombstoneState(chatID: String) -> TombstoneState {
        switch tombstoneSnapshot(chatID: chatID) {
        case .absent: return .absent
        case .present: return .present
        case .unknown: return .unknown
        }
    }

    /// Capture both identity and generation so descriptor verification can be
    /// consumed later without authorizing a different deletion that raced the
    /// workspace scan.
    func tombstoneSnapshot(chatID: String) -> TombstoneSnapshotState {
        // A malformed id is unanswerable rather than provably undeleted; the
        // store never wrote one, so nothing legitimate is refused here.
        guard Self.validChatID(chatID) else { return .unknown }
        do {
            let database = try openDatabase()
            guard try tableExists("deleted_chats", database: database) else { return .absent }
            var generation: Int64?
            try withStatement(
                "SELECT generation FROM deleted_chats WHERE chat_id = ? LIMIT 1",
                database: database
            ) {
                try bind(chatID, at: 1, statement: $0, database: database)
                if try stepRow($0, database: database) {
                    generation = sqlite3_column_int64($0, 0)
                }
            }
            guard let generation else { return .absent }
            return .present(TombstoneSnapshot(chatID: chatID, generation: generation))
        } catch {
            return .unknown
        }
    }

    /// Snapshot every tombstone generation that existed before a later full
    /// workspace archive read. Callers may release only members of this set
    /// that the later archive proves have no descriptor. `nil` means the scan
    /// could not be completed and therefore authorizes no reclamation.
    func tombstoneSnapshots() -> Set<TombstoneSnapshot>? {
        do {
            let database = try openDatabase()
            guard try tableExists("deleted_chats", database: database) else { return [] }
            var snapshots = Set<TombstoneSnapshot>()
            try withStatement(
                "SELECT chat_id, generation FROM deleted_chats",
                database: database
            ) { statement in
                while try stepRow(statement, database: database) {
                    guard let chatID = Self.columnString(statement, column: 0) else {
                        throw StoreError.corruptRecord(
                            "stored transcript deletion identifier could not be read"
                        )
                    }
                    snapshots.insert(TombstoneSnapshot(
                        chatID: chatID,
                        generation: sqlite3_column_int64(statement, 1)
                    ))
                }
            }
            return snapshots
        } catch {
            return nil
        }
    }

    /// Throwing probe shared by every in-actor caller. Database-open, table
    /// inspection, prepare, bind, and step failures all propagate: a transient
    /// SQLite error must never read as "this chat was never deleted".
    private func hasTombstone(chatID: String, database: SQLiteHandle) throws -> Bool {
        guard try tableExists("deleted_chats", database: database) else { return false }
        var found = false
        try withStatement(
            "SELECT 1 FROM deleted_chats WHERE chat_id = ? LIMIT 1",
            database: database
        ) {
            try bind(chatID, at: 1, statement: $0, database: database)
            found = try stepRow($0, database: database)
        }
        return found
    }

    /// Resume any deletion interrupted after its durable tombstone commit,
    /// then drain tombstones whose chat rows are fully gone. Both statements
    /// share one transaction so a failed launch cleanup retains the fence for
    /// the next retry instead of stranding transcript bytes without intent.
    func vacuumTombstones(
        now: Int64? = nil,
        descriptorPruningVerified: Set<TombstoneSnapshot> = []
    ) {
        guard let database = try? openDatabase(),
              (try? tableExists("deleted_chats", database: database)) == true else { return }
        try? transaction(database) {
            try expireWriterLeases(now: Self.timestamp(now), database: database)
        }
        // Isolate receipts transactionally. One generation that became stale
        // must not roll back independent, still-current verified deletions.
        for snapshot in descriptorPruningVerified {
            try? transaction(database) {
                try releaseDescriptorFence(snapshot, database: database)
                // `transcript_rows` follows through ON DELETE CASCADE. Limit
                // both physical deletion and tombstone reclamation to the
                // exact generation whose descriptor was verified; a newer
                // deletion for the same chat remains blocked and untouched.
                try deleteChat(forReleased: snapshot, database: database)
                try reclaimEligibleTombstone(snapshot, database: database)
            }
        }
        try? transaction(database) {
            // A prior exact transaction may have left an unblocked tombstone
            // waiting only for an older writer lease to retire. Global
            // reclamation is safe because creation/upsert and the v6 migration
            // make every unverified tombstone blocked by default.
            try reclaimEligibleTombstones(database)
        }
    }

    /// Release the last exact-generation cleanup fence only after callers have
    /// removed every non-SQLite plaintext copy (the workspace draft plus both
    /// current and migrated UserDefaults keys). Keeping this independent from
    /// `remove` makes a crash after transcript deletion retryable on launch.
    @discardableResult
    func completeExternalCleanup(
        _ snapshot: TombstoneSnapshot,
        performExternalCleanup: @Sendable () throws -> Void = {}
    ) -> Removal {
        guard Self.validChatID(snapshot.chatID) else {
            return .failed(.database("invalid transcript chat identifier"))
        }
        do {
            let database = try openDatabase()
            try transaction(database) {
                let currentReceipt = try withStatement(
                    "SELECT 1 FROM deleted_chats WHERE chat_id = ? AND generation = ? LIMIT 1",
                    database: database
                ) { statement in
                    try bind(snapshot.chatID, at: 1, statement: statement, database: database)
                    try bind(snapshot.generation, at: 2, statement: statement, database: database)
                    return try stepRow(statement, database: database)
                }
                guard currentReceipt else {
                    throw StoreError.database(
                        "transcript deletion cleanup receipt is stale or no longer present"
                    )
                }
                // Run synchronous external cleanup while this exact receipt's
                // SQLite write transaction excludes a retombstone or id reuse.
                // A delayed g1 caller therefore cannot touch g2 plaintext.
                try performExternalCleanup()
                try withStatement(
                    """
                    UPDATE deleted_chats
                    SET external_cleanup_blocked = 0
                    WHERE chat_id = ? AND generation = ?
                    """,
                    database: database
                ) {
                    try bind(snapshot.chatID, at: 1, statement: $0, database: database)
                    try bind(snapshot.generation, at: 2, statement: $0, database: database)
                    try stepDone($0, database: database)
                }
                guard sqlite3_changes(database.pointer) == 1 else {
                    throw StoreError.database(
                        "transcript deletion cleanup receipt is stale or no longer present"
                    )
                }
                try expireWriterLeases(now: Self.timestamp(nil), database: database)
                try reclaimEligibleTombstone(snapshot, database: database)
                try reclaimEligibleTombstones(database)
            }
            return .removed
        } catch {
            return .failed(Self.storeError(error))
        }
    }

    private func tableExists(_ name: String, database: SQLiteHandle) throws -> Bool {
        try withStatement(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            database: database
        ) { statement in
            try bind(name, at: 1, statement: statement, database: database)
            return try stepRow(statement, database: database)
        }
    }

    func flush() {
        flush(chatIDs: nil)
    }

    private func flush(chatIDs: Set<String>?) {
        flushTask = nil
        guard !pending.isEmpty else { return }
        let eligibleChatIDs = Set(pending.keys.filter { chatID in
            (chatIDs == nil || chatIDs?.contains(chatID) == true)
                && persistenceAttempts[chatID, default: 0] < Self.maximumPersistenceAttempts
        })
        guard !eligibleChatIDs.isEmpty else { return }
        let writes = pending.filter { eligibleChatIDs.contains($0.key) }
        for chatID in eligibleChatIDs { pending.removeValue(forKey: chatID) }
        do {
            try consumeFlushFailure()
            let database = try openDatabase()
            let now = Self.timestamp(nil)
            var completedGeneration: Int64 = 0
            try transaction(database) {
                completedGeneration = try currentDeletionGeneration(database)
                let acknowledgedGeneration = writes.values.reduce(
                    writerGeneration ?? completedGeneration
                ) { min($0, $1.writerGeneration) }
                try upsertWriterLease(
                    acknowledgedGeneration: acknowledgedGeneration,
                    now: now,
                    database: database
                )
                for chatID in writes.keys.sorted() {
                    guard let write = writes[chatID] else { continue }
                    // Exact per-chat watermarks and durable incarnation rows
                    // are the authority. An unrelated deletion may advance the
                    // global counter without invalidating this live chat.
                    guard try writeIsAuthorized(
                        write,
                        chatID: chatID,
                        database: database
                    ) else { continue }
                    // A buffered write racing a deletion (a final stream chunk
                    // landing as the user hits delete) must not re-materialize
                    // tombstoned content 350ms later (§4e). A probe that cannot
                    // complete fails closed: it throws, the transaction rolls
                    // back, and the coalesced snapshots below stay queued for a
                    // later retry rather than being written unverified.
                    guard try !hasTombstone(chatID: chatID, database: database) else { continue }
                    try apply(write, chatID: chatID, database: database)
                }
                try pruneEmptyChats(database)
                try pruneOldChats(database)
                try retireWriter(database)
                try expireWriterLeases(now: now, database: database)
                try reclaimEligibleTombstones(database)
                try setMetadataValue("1", for: "v2_has_written", database: database)
            }
            writerGeneration = completedGeneration
            writerLeaseExpiresAt = 0
            retentionCheckedChatIDs.formUnion(writes.keys)
            try secureDatabaseFile()
            for chatID in writes.keys {
                clearPersistenceHealth(chatID: chatID)
            }
        } catch {
            // Retain the exact coalesced snapshots. A later stream update or an
            // explicit lifecycle flush retries them instead of silently losing
            // the newest durable tail after an incidental I/O failure.
            for (chatID, write) in writes where pending[chatID] == nil {
                pending[chatID] = write
            }
            for chatID in writes.keys {
                let attempt = min(
                    Self.maximumPersistenceAttempts,
                    persistenceAttempts[chatID, default: 0] + 1
                )
                persistenceAttempts[chatID] = attempt
                if attempt == Self.maximumPersistenceAttempts {
                    publishPersistenceHealth(
                        .failed(PersistenceFailure(
                            attemptCount: attempt,
                            maximumAttempts: Self.maximumPersistenceAttempts
                        )),
                        chatID: chatID
                    )
                } else {
                    publishPersistenceHealth(
                        .retrying(
                            attempt: attempt,
                            maximumAttempts: Self.maximumPersistenceAttempts
                        ),
                        chatID: chatID
                    )
                }
            }
            scheduleFlush()
        }
    }

    // MARK: - SQLite lifecycle and migration

    private func openDatabase() throws -> SQLiteHandle {
        if let databaseHandle { return databaseHandle }
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try Self.validateDatabaseLeaf(databaseURL)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map(Self.errorMessage) ?? "could not open database"
            if let handle { sqlite3_close_v2(handle) }
            throw StoreError.database(message)
        }

        let database = SQLiteHandle(handle)
        do {
            // Close the brief create-to-chmod window before schema or legacy
            // bytes enter the file. SQLite's rollback journal inherits this
            // private database ownership contract.
            try secureDatabaseFile()
            try execute("PRAGMA foreign_keys = ON", database: database)
            try execute("PRAGMA trusted_schema = OFF", database: database)
            try enableSecureDeletion(database)
            try execute("PRAGMA journal_mode = DELETE", database: database)
            try execute("PRAGMA synchronous = FULL", database: database)
            _ = sqlite3_busy_timeout(database.pointer, 3_000)
            try transaction(database) {
                try createSchema(database)
                try migrateLegacyArchiveIfNeeded(database)
                try migrateChatIncarnationsIfNeeded(database)
            }
            try secureDatabaseFile()
            databaseHandle = database
            return database
        } catch {
            throw error
        }
    }

    private func createSchema(_ database: SQLiteHandle) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS store_meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            ) WITHOUT ROWID
            """,
            database: database
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS chats (
                chat_id TEXT PRIMARY KEY NOT NULL,
                updated_at INTEGER NOT NULL,
                usage_json BLOB,
                draft TEXT,
                attachments_json BLOB,
                session_id TEXT,
                quota_truncated_rows INTEGER NOT NULL DEFAULT 0 CHECK (quota_truncated_rows >= 0),
                quota_truncated_bytes INTEGER NOT NULL DEFAULT 0 CHECK (quota_truncated_bytes >= 0)
            ) WITHOUT ROWID
            """,
            database: database
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS transcript_rows (
                chat_id TEXT NOT NULL REFERENCES chats(chat_id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
                row_json BLOB NOT NULL,
                quota_pinned INTEGER NOT NULL DEFAULT 0 CHECK (quota_pinned IN (0, 1)),
                PRIMARY KEY (chat_id, ordinal)
            ) WITHOUT ROWID
            """,
            database: database
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS chats_by_recency ON chats(updated_at DESC, chat_id ASC)",
            database: database
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS transcript_writers (
                writer_id TEXT PRIMARY KEY NOT NULL,
                acknowledged_generation INTEGER NOT NULL CHECK (acknowledged_generation >= 0),
                lease_expires_at INTEGER NOT NULL CHECK (lease_expires_at >= 0)
            ) WITHOUT ROWID
            """,
            database: database
        )
        if try metadataValue(for: "deletion_generation", database: database) == nil {
            try setMetadataValue("0", for: "deletion_generation", database: database)
        }
        try migrateRetentionSchemaIfNeeded(database)
        try ensureDeletedChatsTable(database)
        try migrateDeletedChatsGenerationIfNeeded(database)
        try migrateDeletedChatsDescriptorFenceIfNeeded(database)
        try migrateDeletedChatsExternalCleanupFenceIfNeeded(database)
        try ensureDeletionWatermarksTable(database)
        try execute("PRAGMA user_version = 9", database: database)
    }

    private func migrateRetentionSchemaIfNeeded(_ database: SQLiteHandle) throws {
        if try !tableHasColumn("chats", column: "quota_truncated_rows", database: database) {
            try execute(
                "ALTER TABLE chats ADD COLUMN quota_truncated_rows INTEGER NOT NULL DEFAULT 0 CHECK (quota_truncated_rows >= 0)",
                database: database
            )
        }
        if try !tableHasColumn("chats", column: "quota_truncated_bytes", database: database) {
            try execute(
                "ALTER TABLE chats ADD COLUMN quota_truncated_bytes INTEGER NOT NULL DEFAULT 0 CHECK (quota_truncated_bytes >= 0)",
                database: database
            )
        }
        if try !tableHasColumn("transcript_rows", column: "quota_pinned", database: database) {
            try execute(
                "ALTER TABLE transcript_rows ADD COLUMN quota_pinned INTEGER NOT NULL DEFAULT 0 CHECK (quota_pinned IN (0, 1))",
                database: database
            )
        }
        guard try metadataValue(for: "retention_pin_classification", database: database) != "1" else {
            return
        }
        try withStatement(
            "SELECT chat_id, ordinal, row_json FROM transcript_rows ORDER BY chat_id, ordinal",
            database: database
        ) { statement in
            while try stepRow(statement, database: database) {
                guard let chatID = Self.columnString(statement, column: 0),
                      let data = Self.columnData(statement, column: 2),
                      let row = try? decoder.decode(AcpTranscriptRow.self, from: data) else {
                    throw StoreError.corruptRecord("stored transcript row could not be classified")
                }
                guard Self.isPinnedEvidence(row) else { continue }
                let ordinal = sqlite3_column_int64(statement, 1)
                try withStatement(
                    "UPDATE transcript_rows SET quota_pinned = 1 WHERE chat_id = ? AND ordinal = ?",
                    database: database
                ) { update in
                    try bind(chatID, at: 1, statement: update, database: database)
                    try bind(ordinal, at: 2, statement: update, database: database)
                    try stepDone(update, database: database)
                }
            }
        }
        try setMetadataValue("1", for: "retention_pin_classification", database: database)
    }

    private func ensureDeletedChatsTable(_ database: SQLiteHandle) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS deleted_chats (
                chat_id TEXT PRIMARY KEY NOT NULL,
                deleted_at INTEGER NOT NULL,
                generation INTEGER NOT NULL CHECK (generation >= 0),
                descriptor_reclaim_blocked INTEGER NOT NULL DEFAULT 1
                    CHECK (descriptor_reclaim_blocked IN (0, 1)),
                external_cleanup_blocked INTEGER NOT NULL DEFAULT 1
                    CHECK (external_cleanup_blocked IN (0, 1))
            ) WITHOUT ROWID
            """,
            database: database
        )
        // A database created before its first deletion has no migration marker
        // yet. Establish it before the first INSERT so a later reopen never
        // mistakes an intentionally released row for an installed-v5 row.
        try migrateDeletedChatsDescriptorFenceIfNeeded(database)
        try migrateDeletedChatsExternalCleanupFenceIfNeeded(database)
        try ensureDeletionWatermarksTable(database)
    }

    private func ensureDeletionWatermarksTable(_ database: SQLiteHandle) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS deletion_watermarks (
                chat_id TEXT PRIMARY KEY NOT NULL,
                generation INTEGER NOT NULL CHECK (generation >= 0),
                deleted_at INTEGER NOT NULL
            ) WITHOUT ROWID
            """,
            database: database
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS deletion_watermarks_by_age ON deletion_watermarks(deleted_at ASC, generation ASC)",
            database: database
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS chat_incarnations (
                chat_id TEXT PRIMARY KEY NOT NULL,
                generation INTEGER NOT NULL CHECK (generation >= 0),
                created_at INTEGER NOT NULL
            ) WITHOUT ROWID
            """,
            database: database
        )
        if try tableExists("deleted_chats", database: database),
           try deletedChatsHaveGenerationColumn(database) {
            try execute(
                """
                INSERT INTO deletion_watermarks(chat_id, generation, deleted_at)
                SELECT chat_id, generation, deleted_at FROM deleted_chats
                WHERE 1
                ON CONFLICT(chat_id) DO UPDATE SET
                    generation = MAX(deletion_watermarks.generation, excluded.generation),
                    deleted_at = MAX(deletion_watermarks.deleted_at, excluded.deleted_at)
                """,
                database: database
            )
        }
        if try metadataValue(
            for: "deletion_watermarks_require_explicit_creation",
            database: database
        ) == nil {
            try setMetadataValue(
                "0",
                for: "deletion_watermarks_require_explicit_creation",
                database: database
            )
        }
    }

    /// Install durable live-incarnation evidence exactly once. Repeating this
    /// backfill after watermark compaction would let a stale writer-created
    /// `chats` row become authority, so the completion marker is part of the
    /// anti-resurrection contract rather than just a migration optimization.
    private func migrateChatIncarnationsIfNeeded(_ database: SQLiteHandle) throws {
        guard try metadataValue(
            for: "chat_incarnation_backfill_complete",
            database: database
        ) != "1" else { return }

        if try tableExists("chat_creation_authorizations", database: database) {
            try execute(
                """
                INSERT INTO chat_incarnations(chat_id, generation, created_at)
                SELECT authorization.chat_id,
                       authorization.generation,
                       authorization.authorized_at
                FROM chat_creation_authorizations AS authorization
                WHERE NOT EXISTS (
                    SELECT 1 FROM deleted_chats
                    WHERE deleted_chats.chat_id = authorization.chat_id
                )
                  AND NOT EXISTS (
                    SELECT 1 FROM deletion_watermarks AS watermark
                    WHERE watermark.chat_id = authorization.chat_id
                      AND watermark.generation >= authorization.generation
                )
                ON CONFLICT(chat_id) DO UPDATE SET
                    generation = MAX(chat_incarnations.generation, excluded.generation)
                """,
                database: database
            )
            try execute("DROP TABLE chat_creation_authorizations", database: database)
        }

        let generation = try currentDeletionGeneration(database)
        try withStatement(
            """
            INSERT INTO chat_incarnations(chat_id, generation, created_at)
            SELECT chats.chat_id, ?, chats.updated_at
            FROM chats
            WHERE NOT EXISTS (
                SELECT 1 FROM deleted_chats
                WHERE deleted_chats.chat_id = chats.chat_id
            )
              AND NOT EXISTS (
                SELECT 1 FROM deletion_watermarks
                WHERE deletion_watermarks.chat_id = chats.chat_id
            )
            ON CONFLICT(chat_id) DO NOTHING
            """,
            database: database
        ) { statement in
            try bind(generation, at: 1, statement: statement, database: database)
            try stepDone(statement, database: database)
        }
        guard try chatIncarnationCount(database) <= Self.maximumChatIncarnations else {
            throw StoreError.database("installed transcript chat incarnations exceed the safe bound")
        }
        try setMetadataValue(
            "1",
            for: "chat_incarnation_backfill_complete",
            database: database
        )
    }

    /// Existing v2 databases may already contain the two-column tombstone
    /// table. Assign every such durable delete one freshly advanced generation
    /// so new writer leases cannot mistake it for an already-acknowledged era.
    private func migrateDeletedChatsGenerationIfNeeded(_ database: SQLiteHandle) throws {
        guard try tableExists("deleted_chats", database: database) else { return }
        guard try !deletedChatsHaveGenerationColumn(database) else { return }
        try execute(
            "ALTER TABLE deleted_chats ADD COLUMN generation INTEGER NOT NULL DEFAULT 0",
            database: database
        )
        let retainedCount = try withStatement(
            "SELECT COUNT(*) FROM deleted_chats",
            database: database
        ) { statement in
            guard try stepRow(statement, database: database) else { return Int64(0) }
            return sqlite3_column_int64(statement, 0)
        }
        guard retainedCount > 0 else { return }
        let generation = try nextDeletionGeneration(database)
        try withStatement(
            "UPDATE deleted_chats SET generation = ?",
            database: database
        ) { statement in
            try bind(generation, at: 1, statement: statement, database: database)
            try stepDone(statement, database: database)
        }
    }

    private func deletedChatsHaveGenerationColumn(_ database: SQLiteHandle) throws -> Bool {
        try tableHasColumn("deleted_chats", column: "generation", database: database)
    }

    private func migrateDeletedChatsDescriptorFenceIfNeeded(_ database: SQLiteHandle) throws {
        guard try tableExists("deleted_chats", database: database) else { return }
        if try !tableHasColumn(
            "deleted_chats",
            column: "descriptor_reclaim_blocked",
            database: database
        ) {
            try execute(
                """
                ALTER TABLE deleted_chats
                ADD COLUMN descriptor_reclaim_blocked INTEGER NOT NULL DEFAULT 1
                    CHECK (descriptor_reclaim_blocked IN (0, 1))
                """,
                database: database
            )
        }
        guard try metadataValue(
            for: "descriptor_fences_blocked",
            database: database
        ) != "1" else { return }
        try execute(
            "UPDATE deleted_chats SET descriptor_reclaim_blocked = 1",
            database: database
        )
        try setMetadataValue("1", for: "descriptor_fences_blocked", database: database)
    }

    private func migrateDeletedChatsExternalCleanupFenceIfNeeded(
        _ database: SQLiteHandle
    ) throws {
        guard try tableExists("deleted_chats", database: database) else { return }
        if try !tableHasColumn(
            "deleted_chats",
            column: "external_cleanup_blocked",
            database: database
        ) {
            try execute(
                """
                ALTER TABLE deleted_chats
                ADD COLUMN external_cleanup_blocked INTEGER NOT NULL DEFAULT 1
                    CHECK (external_cleanup_blocked IN (0, 1))
                """,
                database: database
            )
        }
        guard try metadataValue(
            for: "external_cleanup_fences_blocked",
            database: database
        ) != "1" else { return }
        try execute(
            "UPDATE deleted_chats SET external_cleanup_blocked = 1",
            database: database
        )
        try setMetadataValue(
            "1",
            for: "external_cleanup_fences_blocked",
            database: database
        )
    }

    private func tableHasColumn(
        _ table: String,
        column: String,
        database: SQLiteHandle
    ) throws -> Bool {
        try withStatement("PRAGMA table_info(\(table))", database: database) { statement in
            while try stepRow(statement, database: database) {
                if Self.columnString(statement, column: 1) == column { return true }
            }
            return false
        }
    }

    /// Import the v1 monolithic JSON inside the same immediate transaction that
    /// creates the schema. The source file is never renamed or deleted. A
    /// decode/insert failure rolls every destination row back and leaves the
    /// marker absent, so the next launch can retry the exact source bytes.
    private func migrateLegacyArchiveIfNeeded(_ database: SQLiteHandle) throws {
        let previousFingerprint = try metadataValue(for: "legacy_v1_import", database: database)
        guard let legacyJSONURL,
              FileManager.default.fileExists(atPath: legacyJSONURL.path) else {
            if previousFingerprint == nil {
                try setMetadataValue("absent", for: "legacy_v1_import", database: database)
            }
            return
        }
        try Self.validateLegacyLeaf(legacyJSONURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: legacyJSONURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount <= Self.maximumLegacyArchiveBytes else {
            throw StoreError.legacyArchiveTooLarge(maxBytes: Self.maximumLegacyArchiveBytes)
        }
        let data = try Data(contentsOf: legacyJSONURL, options: [.mappedIfSafe])
        let fingerprint = "sha256:" + SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        if previousFingerprint == fingerprint { return }
        // A rollback build may write the preserved JSON after v2 has become
        // authoritative. Never merge two independently advancing histories.
        // The only retry exception is an empty, never-written v2 database (for
        // example one pre-created by a launch probe before the final v1 save).
        let hasV2Writes = try metadataValue(for: "v2_has_written", database: database) == "1"
        let existingChatCount = try chatCount(database)
        if hasV2Writes || existingChatCount > 0 {
            return
        }
        guard let payload = try? decoder.decode(LegacyPayload.self, from: data) else {
            throw StoreError.corruptLegacyArchive
        }
        for chatID in payload.entries.keys.sorted() {
            guard Self.validChatID(chatID), let entry = payload.entries[chatID] else {
                throw StoreError.corruptLegacyArchive
            }
            try ensureChat(chatID, updatedAt: max(0, entry.updatedAt), database: database)
            if let usage = entry.usage {
                try updateBlob(
                    column: "usage_json",
                    data: try encoder.encode(usage),
                    chatID: chatID,
                    database: database
                )
            }
            for (index, row) in entry.rows.enumerated() {
                try insertRow(
                    row,
                    chatID: chatID,
                    ordinal: Int64(index),
                    database: database
                )
            }
        }
        try pruneOldChats(database)
        try setMetadataValue(fingerprint, for: "legacy_v1_import", database: database)
    }

    private func secureDatabaseFile() throws {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
    }

    // MARK: - Writes

    private func apply(_ write: PendingWrite, chatID: String, database: SQLiteHandle) throws {
        try ensureChat(chatID, updatedAt: write.updatedAt, database: database)
        if let rowWrite = write.rows {
            try applyRows(rowWrite, chatID: chatID, database: database)
        } else {
            try enforceRetentionPolicy(chatID: chatID, database: database)
        }
        switch write.usage {
        case .unchanged: break
        case let .set(value):
            try updateBlob(
                column: "usage_json",
                data: try value.map(encoder.encode),
                chatID: chatID,
                database: database
            )
        }
        switch write.draft {
        case .unchanged: break
        case let .set(value):
            try updateText(column: "draft", value: value, chatID: chatID, database: database)
        }
        switch write.attachments {
        case .unchanged: break
        case let .set(value):
            try updateBlob(
                column: "attachments_json",
                data: try value.map(encoder.encode),
                chatID: chatID,
                database: database
            )
        }
        switch write.sessionID {
        case .unchanged: break
        case let .set(value):
            try updateText(column: "session_id", value: value, chatID: chatID, database: database)
        }
    }

    private func ensureChat(_ chatID: String, updatedAt: Int64, database: SQLiteHandle) throws {
        try withStatement(
            """
            INSERT INTO chats(chat_id, updated_at) VALUES (?, ?)
            ON CONFLICT(chat_id) DO UPDATE SET updated_at = MAX(chats.updated_at, excluded.updated_at)
            """,
            database: database
        ) {
            try bind(chatID, at: 1, statement: $0, database: database)
            sqlite3_bind_int64($0, 2, max(0, updatedAt))
            try stepDone($0, database: database)
        }
    }

    private func applyRows(
        _ write: RowWrite,
        chatID: String,
        database: SQLiteHandle
    ) throws {
        // An upgraded database can begin above the new contract. Reduce that
        // prefix in bounded batches before combining it with this snapshot.
        try enforceRetentionPolicy(chatID: chatID, database: database)
        guard try validSnapshotBoundary(
            chatID: chatID,
            startOrdinal: write.startOrdinal,
            database: database
        ) else {
            throw StoreError.invalidSnapshot
        }
        try withStatement(
            "DELETE FROM transcript_rows WHERE chat_id = ? AND ordinal >= ?",
            database: database
        ) { statement in
            try bind(chatID, at: 1, statement: statement, database: database)
            try bind(write.startOrdinal, at: 2, statement: statement, database: database)
            try stepDone(statement, database: database)
        }

        var candidates = try retentionCandidates(chatID: chatID, database: database)
        candidates.reserveCapacity(candidates.count + write.rows.count)
        for (offset, row) in write.rows.enumerated() {
            let data = try encoder.encode(row)
            candidates.append(RetentionCandidate(
                ordinal: write.startOrdinal + Int64(offset),
                byteCount: data.count,
                isPinnedEvidence: Self.isPinnedEvidence(row),
                isPending: true
            ))
        }
        let removed = retentionEvictions(from: candidates)
        try deleteRetentionCandidates(
            candidates.filter { !$0.isPending && removed.contains($0.ordinal) },
            chatID: chatID,
            database: database
        )
        for (offset, row) in write.rows.enumerated() {
            let ordinal = write.startOrdinal + Int64(offset)
            guard !removed.contains(ordinal) else { continue }
            try insertEncodedRow(
                encoder.encode(row),
                pinned: Self.isPinnedEvidence(row),
                chatID: chatID,
                ordinal: ordinal,
                database: database
            )
        }
        try recordRetentionEvictions(
            candidates.filter { removed.contains($0.ordinal) },
            chatID: chatID,
            database: database
        )
    }

    private func enforceRetentionPolicy(chatID: String, database: SQLiteHandle) throws {
        var totals = try retentionTotals(chatID: chatID, database: database)
        var removedRows: Int64 = 0
        var removedBytes: Int64 = 0
        while totals.count > retentionPolicy.maximumRowCount
                || totals.bytes > Int64(retentionPolicy.maximumBytes) {
            let recentCutoff = try retentionRecentCutoff(
                chatID: chatID,
                rowCount: totals.count,
                database: database
            )
            let batch = try retentionEvictionBatch(
                chatID: chatID,
                recentCutoff: recentCutoff,
                database: database
            )
            guard !batch.isEmpty else {
                throw StoreError.database("transcript quota could not select an eviction candidate")
            }
            var selected: [RetentionCandidate] = []
            for candidate in batch {
                guard totals.count > retentionPolicy.maximumRowCount
                        || totals.bytes > Int64(retentionPolicy.maximumBytes) else { break }
                selected.append(candidate)
                totals.count -= 1
                totals.bytes = max(0, totals.bytes - Int64(candidate.byteCount))
                removedRows = Self.saturatingAdd(removedRows, 1)
                removedBytes = Self.saturatingAdd(removedBytes, Int64(candidate.byteCount))
            }
            try deleteRetentionCandidates(selected, chatID: chatID, database: database)
        }
        try recordRetentionEvictions(
            rows: removedRows,
            bytes: removedBytes,
            chatID: chatID,
            database: database
        )
    }

    private func retentionTotals(
        chatID: String,
        database: SQLiteHandle
    ) throws -> (count: Int, bytes: Int64) {
        try withStatement(
            "SELECT COUNT(*), COALESCE(SUM(length(row_json)), 0) FROM transcript_rows WHERE chat_id = ?",
            database: database
        ) { statement in
            try bind(chatID, at: 1, statement: statement, database: database)
            guard try stepRow(statement, database: database) else { return (0, 0) }
            return (
                max(0, Int(sqlite3_column_int64(statement, 0))),
                max(0, sqlite3_column_int64(statement, 1))
            )
        }
    }

    private func retentionRecentCutoff(
        chatID: String,
        rowCount: Int,
        database: SQLiteHandle
    ) throws -> Int64 {
        guard retentionPolicy.recentRowCount > 0, rowCount > 0 else { return Int64.max }
        let offset = min(rowCount, retentionPolicy.recentRowCount) - 1
        return try withStatement(
            "SELECT ordinal FROM transcript_rows WHERE chat_id = ? ORDER BY ordinal DESC LIMIT 1 OFFSET ?",
            database: database
        ) { statement in
            try bind(chatID, at: 1, statement: statement, database: database)
            sqlite3_bind_int64(statement, 2, Int64(offset))
            guard try stepRow(statement, database: database) else { return Int64.max }
            return sqlite3_column_int64(statement, 0)
        }
    }

    private func retentionEvictionBatch(
        chatID: String,
        recentCutoff: Int64,
        database: SQLiteHandle
    ) throws -> [RetentionCandidate] {
        try withStatement(
            """
            SELECT ordinal, length(row_json), quota_pinned
            FROM transcript_rows WHERE chat_id = ?
            ORDER BY CASE
                WHEN ordinal >= ? THEN 2
                WHEN quota_pinned = 1 THEN 1
                ELSE 0
            END ASC, ordinal ASC
            LIMIT 256
            """,
            database: database
        ) { statement in
            try bind(chatID, at: 1, statement: statement, database: database)
            try bind(recentCutoff, at: 2, statement: statement, database: database)
            var candidates: [RetentionCandidate] = []
            while try stepRow(statement, database: database) {
                candidates.append(RetentionCandidate(
                    ordinal: sqlite3_column_int64(statement, 0),
                    byteCount: max(0, Int(sqlite3_column_int64(statement, 1))),
                    isPinnedEvidence: sqlite3_column_int(statement, 2) == 1,
                    isPending: false
                ))
            }
            return candidates
        }
    }

    private func ensureRetentionPolicyApplied(
        chatID: String,
        database: SQLiteHandle
    ) throws {
        guard !retentionCheckedChatIDs.contains(chatID) else { return }
        try transaction(database) {
            try enforceRetentionPolicy(chatID: chatID, database: database)
        }
        retentionCheckedChatIDs.insert(chatID)
    }

    private func retentionCandidates(
        chatID: String,
        database: SQLiteHandle
    ) throws -> [RetentionCandidate] {
        try withStatement(
            "SELECT ordinal, length(row_json), quota_pinned FROM transcript_rows WHERE chat_id = ? ORDER BY ordinal ASC",
            database: database
        ) { statement in
            try bind(chatID, at: 1, statement: statement, database: database)
            var candidates: [RetentionCandidate] = []
            while try stepRow(statement, database: database) {
                candidates.append(RetentionCandidate(
                    ordinal: sqlite3_column_int64(statement, 0),
                    byteCount: max(0, Int(sqlite3_column_int64(statement, 1))),
                    isPinnedEvidence: sqlite3_column_int(statement, 2) == 1,
                    isPending: false
                ))
            }
            return candidates
        }
    }

    private func retentionEvictions(from candidates: [RetentionCandidate]) -> Set<Int64> {
        var retainedCount = candidates.count
        var retainedBytes = candidates.reduce(into: Int64(0)) { total, candidate in
            total = Self.saturatingAdd(total, Int64(candidate.byteCount))
        }
        let maximumBytes = Int64(retentionPolicy.maximumBytes)
        func isOverQuota() -> Bool {
            retainedCount > retentionPolicy.maximumRowCount || retainedBytes > maximumBytes
        }
        guard isOverQuota() else { return [] }

        let recentStart = max(0, candidates.count - retentionPolicy.recentRowCount)
        let older = candidates[..<recentStart]
        let evictionOrder = older.filter { !$0.isPinnedEvidence }
            + older.filter(\.isPinnedEvidence)
            + candidates[recentStart...]
        var removed: Set<Int64> = []
        for candidate in evictionOrder where isOverQuota() {
            removed.insert(candidate.ordinal)
            retainedCount -= 1
            retainedBytes = max(0, retainedBytes - Int64(candidate.byteCount))
        }
        return removed
    }

    private func deleteRetentionCandidates(
        _ candidates: [RetentionCandidate],
        chatID: String,
        database: SQLiteHandle
    ) throws {
        guard !candidates.isEmpty else { return }
        try withStatement(
            "DELETE FROM transcript_rows WHERE chat_id = ? AND ordinal = ?",
            database: database
        ) { statement in
            for candidate in candidates {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(chatID, at: 1, statement: statement, database: database)
                try bind(candidate.ordinal, at: 2, statement: statement, database: database)
                try stepDone(statement, database: database)
            }
        }
    }

    private func recordRetentionEvictions(
        _ candidates: [RetentionCandidate],
        chatID: String,
        database: SQLiteHandle
    ) throws {
        let removedRows = Int64(candidates.count)
        let removedBytes = candidates.reduce(into: Int64(0)) { total, candidate in
            total = Self.saturatingAdd(total, Int64(candidate.byteCount))
        }
        try recordRetentionEvictions(
            rows: removedRows,
            bytes: removedBytes,
            chatID: chatID,
            database: database
        )
    }

    private func recordRetentionEvictions(
        rows removedRows: Int64,
        bytes removedBytes: Int64,
        chatID: String,
        database: SQLiteHandle
    ) throws {
        guard removedRows > 0 || removedBytes > 0 else { return }
        let current = try retentionStatus(chatID: chatID, database: database)
        try withStatement(
            "UPDATE chats SET quota_truncated_rows = ?, quota_truncated_bytes = ? WHERE chat_id = ?",
            database: database
        ) { statement in
            try bind(Self.saturatingAdd(current.truncatedRowCount, removedRows), at: 1, statement: statement, database: database)
            try bind(Self.saturatingAdd(current.truncatedByteCount, removedBytes), at: 2, statement: statement, database: database)
            try bind(chatID, at: 3, statement: statement, database: database)
            try stepDone(statement, database: database)
        }
    }

    private func retentionStatus(chatID: String, database: SQLiteHandle) throws -> RetentionStatus {
        try withStatement(
            "SELECT quota_truncated_rows, quota_truncated_bytes FROM chats WHERE chat_id = ?",
            database: database
        ) { statement in
            try bind(chatID, at: 1, statement: statement, database: database)
            guard try stepRow(statement, database: database) else { return .empty }
            return RetentionStatus(
                truncatedRowCount: max(0, sqlite3_column_int64(statement, 0)),
                truncatedByteCount: max(0, sqlite3_column_int64(statement, 1))
            )
        }
    }

    private func validSnapshotBoundary(
        chatID: String,
        startOrdinal: Int64,
        database: SQLiteHandle
    ) throws -> Bool {
        guard startOrdinal > 0 else { return startOrdinal == 0 }
        return try withStatement(
            "SELECT MAX(ordinal), SUM(CASE WHEN ordinal = ? THEN 1 ELSE 0 END) FROM transcript_rows WHERE chat_id = ?",
            database: database
        ) { statement in
            try bind(startOrdinal, at: 1, statement: statement, database: database)
            try bind(chatID, at: 2, statement: statement, database: database)
            guard try stepRow(statement, database: database),
                  sqlite3_column_type(statement, 0) != SQLITE_NULL else { return false }
            let maximumOrdinal = sqlite3_column_int64(statement, 0)
            let boundaryExists = sqlite3_column_int64(statement, 1) > 0
            if boundaryExists || maximumOrdinal == startOrdinal - 1 { return true }
            let status = try retentionStatus(chatID: chatID, database: database)
            return status.isTruncated && startOrdinal <= maximumOrdinal + 1
        }
    }

    private static func isPinnedEvidence(_ row: AcpTranscriptRow) -> Bool {
        switch row {
        case .user, .tool, .runProfileAudit: true
        case .message, .thought, .plan, .permissionDecision: false
        }
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        guard rhs > 0 else { return lhs }
        return lhs > Int64.max - rhs ? Int64.max : lhs + rhs
    }

    private func insertRow(
        _ row: AcpTranscriptRow,
        chatID: String,
        ordinal: Int64,
        database: SQLiteHandle
    ) throws {
        let data = try encoder.encode(row)
        try insertEncodedRow(
            data,
            pinned: Self.isPinnedEvidence(row),
            chatID: chatID,
            ordinal: ordinal,
            database: database
        )
    }

    private func insertEncodedRow(
        _ data: Data,
        pinned: Bool,
        chatID: String,
        ordinal: Int64,
        database: SQLiteHandle
    ) throws {
        try withStatement(
            "INSERT INTO transcript_rows(chat_id, ordinal, row_json, quota_pinned) VALUES (?, ?, ?, ?)",
            database: database
        ) {
            try bind(chatID, at: 1, statement: $0, database: database)
            sqlite3_bind_int64($0, 2, ordinal)
            try bind(data, at: 3, statement: $0, database: database)
            sqlite3_bind_int($0, 4, pinned ? 1 : 0)
            try stepDone($0, database: database)
        }
    }

    private func updateBlob(
        column: String,
        data: Data?,
        chatID: String,
        database: SQLiteHandle
    ) throws {
        try withStatement("UPDATE chats SET \(column) = ? WHERE chat_id = ?", database: database) {
            if let data { try bind(data, at: 1, statement: $0, database: database) }
            else { sqlite3_bind_null($0, 1) }
            try bind(chatID, at: 2, statement: $0, database: database)
            try stepDone($0, database: database)
        }
    }

    private func updateText(
        column: String,
        value: String?,
        chatID: String,
        database: SQLiteHandle
    ) throws {
        try withStatement("UPDATE chats SET \(column) = ? WHERE chat_id = ?", database: database) {
            if let value { try bind(value, at: 1, statement: $0, database: database) }
            else { sqlite3_bind_null($0, 1) }
            try bind(chatID, at: 2, statement: $0, database: database)
            try stepDone($0, database: database)
        }
    }

    private func pruneEmptyChats(_ database: SQLiteHandle) throws {
        try execute(
            """
            DELETE FROM chats
            WHERE usage_json IS NULL AND draft IS NULL AND attachments_json IS NULL AND session_id IS NULL
              AND quota_truncated_rows = 0 AND quota_truncated_bytes = 0
              AND NOT EXISTS (
                  SELECT 1 FROM transcript_rows WHERE transcript_rows.chat_id = chats.chat_id
              )
            """,
            database: database
        )
    }

    private func pruneOldChats(_ database: SQLiteHandle) throws {
        try execute(
            """
            DELETE FROM chats WHERE chat_id IN (
                SELECT chat_id FROM chats
                ORDER BY updated_at DESC, chat_id ASC
                LIMIT -1 OFFSET \(Self.maximumChatCount)
            )
            """,
            database: database
        )
    }

    // MARK: - Reads

    private func readMetadata(chatID: String, database: SQLiteHandle) throws -> StoredMetadata? {
        try withStatement(
            """
            SELECT updated_at, usage_json, draft, attachments_json, session_id,
                   quota_truncated_rows, quota_truncated_bytes
            FROM chats WHERE chat_id = ?
            """,
            database: database
        ) { statement in
            try bind(chatID, at: 1, statement: statement, database: database)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw databaseError(database) }
            let usage: AcpPersistedUsage? = try decodedBlob(
                AcpPersistedUsage.self,
                column: 1,
                statement: statement
            )
            let attachments = try decodedBlob(
                [AcpAttachment].self,
                column: 3,
                statement: statement
            ) ?? []
            let draft = Self.columnString(statement, column: 2)
            let sessionID = Self.columnString(statement, column: 4)
            guard Self.attachmentsAreBounded(attachments) else {
                throw StoreError.corruptRecord("stored attachments exceed the bounded contract")
            }
            guard draft?.lengthOfBytes(using: .utf8) ?? 0 <= Self.maximumDraftBytes,
                  sessionID?.lengthOfBytes(using: .utf8) ?? 0 <= 4_096 else {
                throw StoreError.corruptRecord("stored transcript metadata exceeds the bounded contract")
            }
            return StoredMetadata(
                updatedAt: sqlite3_column_int64(statement, 0),
                usage: usage,
                draft: draft,
                attachments: attachments,
                sessionID: sessionID,
                retentionStatus: RetentionStatus(
                    truncatedRowCount: max(0, sqlite3_column_int64(statement, 5)),
                    truncatedByteCount: max(0, sqlite3_column_int64(statement, 6))
                )
            )
        }
    }

    private func readAllRows(chatID: String, database: SQLiteHandle) throws -> [AcpTranscriptRow] {
        try readAllOrdinalRows(chatID: chatID, database: database).map(\.row)
    }

    private func readAllOrdinalRows(
        chatID: String,
        database: SQLiteHandle
    ) throws -> [(ordinal: Int64, row: AcpTranscriptRow)] {
        try withStatement(
            "SELECT ordinal, row_json FROM transcript_rows WHERE chat_id = ? ORDER BY ordinal ASC",
            database: database
        ) { statement in
            try bind(chatID, at: 1, statement: statement, database: database)
            var rows: [(ordinal: Int64, row: AcpTranscriptRow)] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return rows }
                guard result == SQLITE_ROW,
                      let data = Self.columnData(statement, column: 1),
                      let row = try? decoder.decode(AcpTranscriptRow.self, from: data) else {
                    throw StoreError.corruptRecord("stored transcript row could not be decoded")
                }
                rows.append((sqlite3_column_int64(statement, 0), row))
            }
        }
    }

    private func readTailPage(chatID: String, limit: Int, database: SQLiteHandle) throws -> Page {
        let total = try rowCount(chatID: chatID, beforeOrdinal: nil, database: database)
        guard total > 0 else { return .empty }
        return try readDescendingPage(
            chatID: chatID,
            predicate: "",
            boundary: nil,
            limit: limit,
            total: total,
            database: database
        )
    }

    private func readPage(
        chatID: String,
        beforeOrdinal: Int64,
        limit: Int,
        database: SQLiteHandle
    ) throws -> Page {
        let total = try rowCount(chatID: chatID, beforeOrdinal: nil, database: database)
        let available = try rowCount(
            chatID: chatID,
            beforeOrdinal: beforeOrdinal,
            database: database
        )
        guard available > 0 else {
            return Page(
                rows: [],
                startOrdinal: beforeOrdinal,
                endOrdinalExclusive: beforeOrdinal,
                earlierRowCount: 0,
                totalRowCount: total
            )
        }
        return try readDescendingPage(
            chatID: chatID,
            predicate: "AND ordinal < ?",
            boundary: beforeOrdinal,
            limit: min(limit, available),
            total: total,
            database: database
        )
    }

    private func readDescendingPage(
        chatID: String,
        predicate: String,
        boundary: Int64?,
        limit: Int,
        total: Int,
        database: SQLiteHandle
    ) throws -> Page {
        try withStatement(
            """
            SELECT ordinal, row_json FROM transcript_rows
            WHERE chat_id = ? \(predicate)
            ORDER BY ordinal DESC LIMIT ?
            """,
            database: database
        ) { statement in
            try bind(chatID, at: 1, statement: statement, database: database)
            var limitIndex: Int32 = 2
            if let boundary {
                sqlite3_bind_int64(statement, 2, boundary)
                limitIndex = 3
            }
            sqlite3_bind_int(statement, limitIndex, Int32(limit))
            var decoded: [(Int64, AcpTranscriptRow)] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let data = Self.columnData(statement, column: 1),
                      let row = try? decoder.decode(AcpTranscriptRow.self, from: data) else {
                    throw StoreError.corruptRecord("stored transcript row could not be decoded")
                }
                decoded.append((sqlite3_column_int64(statement, 0), row))
            }
            decoded.reverse()
            guard let first = decoded.first, let last = decoded.last else { return .empty }
            let earlier = try rowCount(
                chatID: chatID,
                beforeOrdinal: first.0,
                database: database
            )
            return Page(
                rows: decoded.map(\.1),
                startOrdinal: first.0,
                // Quota pruning can leave intentional ordinal gaps. A page
                // requested before a loaded boundary still joins that boundary
                // even when its newest retained evidence row is older.
                endOrdinalExclusive: boundary ?? (last.0 + 1),
                earlierRowCount: earlier,
                totalRowCount: total
            )
        }
    }

    private func rowCount(
        chatID: String,
        beforeOrdinal: Int64?,
        database: SQLiteHandle
    ) throws -> Int {
        let predicate = beforeOrdinal == nil ? "" : " AND ordinal < ?"
        return try withStatement(
            "SELECT COUNT(*) FROM transcript_rows WHERE chat_id = ?\(predicate)",
            database: database
        ) { statement in
            try bind(chatID, at: 1, statement: statement, database: database)
            if let beforeOrdinal { sqlite3_bind_int64(statement, 2, beforeOrdinal) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError(database) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func chatCount(_ database: SQLiteHandle) throws -> Int {
        try withStatement("SELECT COUNT(*) FROM chats", database: database) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError(database) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    // MARK: - SQLite helpers

    private func currentDeletionGeneration(_ database: SQLiteHandle) throws -> Int64 {
        guard let stored = try metadataValue(for: "deletion_generation", database: database),
              let generation = Int64(stored), generation >= 0 else {
            throw StoreError.database("transcript deletion generation is missing or invalid")
        }
        return generation
    }

    private func nextDeletionGeneration(_ database: SQLiteHandle) throws -> Int64 {
        let current = try currentDeletionGeneration(database)
        guard current < Int64.max else {
            throw StoreError.database("transcript deletion generation is exhausted")
        }
        let next = current + 1
        try setMetadataValue(String(next), for: "deletion_generation", database: database)
        return next
    }

    private func deletionWatermarkGeneration(
        chatID: String,
        database: SQLiteHandle
    ) throws -> Int64? {
        guard try tableExists("deletion_watermarks", database: database) else { return nil }
        return try withStatement(
            "SELECT generation FROM deletion_watermarks WHERE chat_id = ? LIMIT 1",
            database: database
        ) { statement in
            try bind(chatID, at: 1, statement: statement, database: database)
            guard try stepRow(statement, database: database) else { return nil }
            return sqlite3_column_int64(statement, 0)
        }
    }

    private func chatIncarnationGeneration(
        chatID: String,
        database: SQLiteHandle
    ) throws -> Int64? {
        guard try tableExists("chat_incarnations", database: database) else {
            return nil
        }
        return try withStatement(
            "SELECT generation FROM chat_incarnations WHERE chat_id = ? LIMIT 1",
            database: database
        ) { statement in
            try bind(chatID, at: 1, statement: statement, database: database)
            guard try stepRow(statement, database: database) else { return nil }
            return sqlite3_column_int64(statement, 0)
        }
    }

    private func chatIncarnationCount(_ database: SQLiteHandle) throws -> Int {
        try withStatement(
            "SELECT COUNT(*) FROM chat_incarnations",
            database: database
        ) { statement in
            guard try stepRow(statement, database: database) else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func requiresExplicitChatCreation(_ database: SQLiteHandle) throws -> Bool {
        try metadataValue(
            for: "deletion_watermarks_require_explicit_creation",
            database: database
        ) == "1"
    }

    private func chatExists(chatID: String, database: SQLiteHandle) throws -> Bool {
        try withStatement(
            "SELECT 1 FROM chats WHERE chat_id = ? LIMIT 1",
            database: database
        ) { statement in
            try bind(chatID, at: 1, statement: statement, database: database)
            return try stepRow(statement, database: database)
        }
    }

    private func writeIsAuthorized(
        _ write: PendingWrite,
        chatID: String,
        database: SQLiteHandle
    ) throws -> Bool {
        let watermark = try deletionWatermarkGeneration(
            chatID: chatID,
            database: database
        )
        if let capturedIncarnation = write.incarnationGeneration {
            guard try chatIncarnationGeneration(
                chatID: chatID,
                database: database
            ) == capturedIncarnation else { return false }
            return watermark.map({ capturedIncarnation > $0 }) ?? true
        }
        guard watermark.map({ write.writerGeneration > $0 }) ?? true else {
            return false
        }
        return try !requiresExplicitChatCreation(database)
    }

    private func writerLeaseIsLive(now: Int64, database: SQLiteHandle) throws -> Bool {
        try withStatement(
            "SELECT lease_expires_at FROM transcript_writers WHERE writer_id = ?",
            database: database
        ) { statement in
            try bind(writerID, at: 1, statement: statement, database: database)
            guard try stepRow(statement, database: database) else { return false }
            return sqlite3_column_int64(statement, 0) > now
        }
    }

    private func upsertWriterLease(
        acknowledgedGeneration: Int64,
        now: Int64,
        database: SQLiteHandle
    ) throws {
        guard acknowledgedGeneration >= 0 else {
            throw StoreError.database("transcript writer generation is invalid")
        }
        try withStatement(
            """
            INSERT INTO transcript_writers(writer_id, acknowledged_generation, lease_expires_at)
            VALUES (?, ?, ?)
            ON CONFLICT(writer_id) DO UPDATE SET
                acknowledged_generation = excluded.acknowledged_generation,
                lease_expires_at = excluded.lease_expires_at
            """,
            database: database
        ) { statement in
            try bind(writerID, at: 1, statement: statement, database: database)
            try bind(acknowledgedGeneration, at: 2, statement: statement, database: database)
            try bind(Self.writerLeaseDeadline(after: now), at: 3, statement: statement, database: database)
            try stepDone(statement, database: database)
        }
    }

    private func retireWriter(_ database: SQLiteHandle) throws {
        try withStatement(
            "DELETE FROM transcript_writers WHERE writer_id = ?",
            database: database
        ) { statement in
            try bind(writerID, at: 1, statement: statement, database: database)
            try stepDone(statement, database: database)
        }
    }

    private func expireWriterLeases(now: Int64, database: SQLiteHandle) throws {
        try withStatement(
            "DELETE FROM transcript_writers WHERE lease_expires_at <= ?",
            database: database
        ) { statement in
            try bind(now, at: 1, statement: statement, database: database)
            try stepDone(statement, database: database)
        }
    }

    private func reclaimEligibleTombstones(_ database: SQLiteHandle) throws {
        guard try tableExists("deleted_chats", database: database) else { return }
        try execute(
            """
            DELETE FROM deleted_chats
            WHERE chat_id NOT IN (SELECT chat_id FROM chats)
              AND descriptor_reclaim_blocked = 0
              AND external_cleanup_blocked = 0
              AND NOT EXISTS (
                  SELECT 1 FROM transcript_writers
                  WHERE acknowledged_generation < deleted_chats.generation
              )
            """,
            database: database
        )
        try pruneDeletionWatermarks(database)
    }

    private func deleteChat(
        forReleased snapshot: TombstoneSnapshot,
        database: SQLiteHandle
    ) throws {
        try withStatement(
            """
            DELETE FROM chats
            WHERE chat_id = ?
              AND EXISTS (
                  SELECT 1 FROM deleted_chats
                  WHERE chat_id = ?
                    AND generation = ?
                    AND descriptor_reclaim_blocked = 0
              )
            """,
            database: database
        ) {
            try bind(snapshot.chatID, at: 1, statement: $0, database: database)
            try bind(snapshot.chatID, at: 2, statement: $0, database: database)
            try bind(snapshot.generation, at: 3, statement: $0, database: database)
            try stepDone($0, database: database)
        }
        try pruneDeletionWatermarks(database)
    }

    private func pruneDeletionWatermarks(_ database: SQLiteHandle) throws {
        guard try tableExists("deletion_watermarks", database: database) else { return }
        let count = try withStatement(
            "SELECT COUNT(*) FROM deletion_watermarks",
            database: database
        ) { statement -> Int in
            guard try stepRow(statement, database: database) else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
        let excess = count - Self.maximumDeletionWatermarks
        guard excess > 0 else { return }

        var candidates: [String] = []
        try withStatement(
            """
            SELECT watermark.chat_id
            FROM deletion_watermarks AS watermark
            WHERE (
                watermark.chat_id NOT IN (SELECT chat_id FROM chats)
                OR EXISTS (
                    SELECT 1 FROM chat_incarnations AS incarnation
                    WHERE incarnation.chat_id = watermark.chat_id
                      AND incarnation.generation > watermark.generation
                )
            )
              AND NOT EXISTS (
                  SELECT 1 FROM transcript_writers
                  WHERE acknowledged_generation <= watermark.generation
              )
            ORDER BY watermark.deleted_at ASC, watermark.generation ASC, watermark.chat_id ASC
            LIMIT ?
            """,
            database: database
        ) { statement in
            try bind(Int64(excess), at: 1, statement: statement, database: database)
            while try stepRow(statement, database: database) {
                guard let chatID = Self.columnString(statement, column: 0) else {
                    throw StoreError.corruptRecord(
                        "stored transcript deletion watermark identifier could not be read"
                    )
                }
                candidates.append(chatID)
            }
        }
        guard !candidates.isEmpty else { return }
        // Once any exact id is compacted, a missing unknown chat is never an
        // implicit creation authorization. Product creation explicitly opts in
        // through `beginNewChatID`, including deliberate future id reuse.
        try setMetadataValue(
            "1",
            for: "deletion_watermarks_require_explicit_creation",
            database: database
        )
        for chatID in candidates {
            try withStatement(
                "DELETE FROM deletion_watermarks WHERE chat_id = ?",
                database: database
            ) { statement in
                try bind(chatID, at: 1, statement: statement, database: database)
                try stepDone(statement, database: database)
            }
        }
    }

    private func reclaimEligibleTombstone(
        _ snapshot: TombstoneSnapshot,
        database: SQLiteHandle
    ) throws {
        try withStatement(
            """
            DELETE FROM deleted_chats
            WHERE chat_id = ?
              AND generation = ?
              AND descriptor_reclaim_blocked = 0
              AND external_cleanup_blocked = 0
              AND chat_id NOT IN (SELECT chat_id FROM chats)
              AND NOT EXISTS (
                  SELECT 1 FROM transcript_writers
                  WHERE acknowledged_generation < deleted_chats.generation
              )
            """,
            database: database
        ) {
            try bind(snapshot.chatID, at: 1, statement: $0, database: database)
            try bind(snapshot.generation, at: 2, statement: $0, database: database)
            try stepDone($0, database: database)
        }
    }

    private func releaseDescriptorFence(
        _ snapshot: TombstoneSnapshot,
        database: SQLiteHandle
    ) throws {
        try withStatement(
            """
            UPDATE deleted_chats
            SET descriptor_reclaim_blocked = 0
            WHERE chat_id = ? AND generation = ?
            """,
            database: database
        ) {
            try bind(snapshot.chatID, at: 1, statement: $0, database: database)
            try bind(snapshot.generation, at: 2, statement: $0, database: database)
            try stepDone($0, database: database)
        }
        guard sqlite3_changes(database.pointer) == 1 else {
            throw StoreError.database(
                "transcript deletion receipt is stale or no longer present"
            )
        }
    }

    private func consumeRemovalFailure(_ point: RemovalFailurePoint) throws {
        guard injectedRemovalFailure == point else { return }
        injectedRemovalFailure = nil
        let label: String
        switch point {
        case .open: label = "open"
        case .delete: label = "DELETE"
        case .commit: label = "commit"
        }
        throw StoreError.database("injected transcript removal \(label) failure")
    }

    private func consumeTombstoneFailure(_ point: TombstoneFailurePoint) throws {
        guard injectedTombstoneFailure == point else { return }
        injectedTombstoneFailure = nil
        let label = point == .open ? "open" : "commit"
        throw StoreError.database("injected transcript tombstone \(label) failure")
    }

    private func consumeFlushFailure() throws {
        guard injectedFlushFailureCount > 0 else { return }
        injectedFlushFailureCount -= 1
        throw StoreError.database("injected transcript flush failure")
    }

    private static func storeError(_ error: Error) -> StoreError {
        error as? StoreError ?? .database(error.localizedDescription)
    }

    private func transaction(
        _ database: SQLiteHandle,
        beforeCommit: () throws -> Void = {},
        body: () throws -> Void
    ) throws {
        try execute("BEGIN IMMEDIATE", database: database)
        do {
            try body()
            try beforeCommit()
            try execute("COMMIT", database: database)
        } catch {
            try? execute("ROLLBACK", database: database)
            throw error
        }
    }

    private func execute(_ sql: String, database: SQLiteHandle) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database.pointer, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? Self.errorMessage(database.pointer)
            sqlite3_free(message)
            throw StoreError.database(detail)
        }
    }

    private func enableSecureDeletion(_ database: SQLiteHandle) throws {
        try execute("PRAGMA secure_delete = ON", database: database)
        let isEnabled = try withStatement("PRAGMA secure_delete", database: database) { statement in
            guard try stepRow(statement, database: database) else { return false }
            return sqlite3_column_int(statement, 0) == 1
        }
        guard isEnabled else {
            throw StoreError.database("SQLite secure-delete policy could not be enabled")
        }
    }

    private func withStatement<Result>(
        _ sql: String,
        database: SQLiteHandle,
        body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database.pointer, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError(database) }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer, database: SQLiteHandle) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(database) }
    }

    /// True when the statement yields a row; DONE means no match.
    private func stepRow(_ statement: OpaquePointer, database: SQLiteHandle) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw databaseError(database)
        }
    }

    private func bind(
        _ value: Int64,
        at index: Int32,
        statement: OpaquePointer,
        database: SQLiteHandle
    ) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw databaseError(database)
        }
    }

    private func bind(
        _ value: String,
        at index: Int32,
        statement: OpaquePointer,
        database: SQLiteHandle
    ) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient) == SQLITE_OK else {
            throw databaseError(database)
        }
    }

    private func bind(
        _ data: Data,
        at index: Int32,
        statement: OpaquePointer,
        database: SQLiteHandle
    ) throws {
        let result = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.sqliteTransient)
        }
        guard result == SQLITE_OK else { throw databaseError(database) }
    }

    private func decodedBlob<Value: Decodable>(
        _ type: Value.Type,
        column: Int32,
        statement: OpaquePointer
    ) throws -> Value? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        guard let data = Self.columnData(statement, column: column) else {
            throw StoreError.corruptRecord("stored metadata blob is missing")
        }
        do { return try decoder.decode(type, from: data) }
        catch { throw StoreError.corruptRecord("stored metadata blob could not be decoded") }
    }

    private func metadataValue(for key: String, database: SQLiteHandle) throws -> String? {
        try withStatement("SELECT value FROM store_meta WHERE key = ?", database: database) { statement in
            try bind(key, at: 1, statement: statement, database: database)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw databaseError(database) }
            return Self.columnString(statement, column: 0)
        }
    }

    private func setMetadataValue(_ value: String, for key: String, database: SQLiteHandle) throws {
        try withStatement(
            "INSERT OR REPLACE INTO store_meta(key, value) VALUES (?, ?)",
            database: database
        ) {
            try bind(key, at: 1, statement: $0, database: database)
            try bind(value, at: 2, statement: $0, database: database)
            try stepDone($0, database: database)
        }
    }

    private func databaseError(_ database: SQLiteHandle) -> StoreError {
        .database(Self.errorMessage(database.pointer))
    }

    private static func errorMessage(_ database: OpaquePointer) -> String {
        sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown SQLite error"
    }

    private static func columnData(_ statement: OpaquePointer, column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count >= 0 else { return nil }
        if count == 0 { return Data() }
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private static func columnString(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func boundedPageLimit(_ requested: Int) -> Int {
        min(max(1, requested), maximumPageSize)
    }

    private static func validChatID(_ chatID: String) -> Bool {
        !chatID.isEmpty && chatID.lengthOfBytes(using: .utf8) <= 1_024
    }

    private static func timestamp(_ supplied: Int64?) -> Int64 {
        max(0, supplied ?? Int64(Date().timeIntervalSince1970 * 1_000))
    }

    private static func writerLeaseDeadline(after now: Int64) -> Int64 {
        if now > Int64.max - writerLeaseDurationMilliseconds { return Int64.max }
        return now + writerLeaseDurationMilliseconds
    }

    private static func attachmentsAreBounded(_ attachments: [AcpAttachment]) -> Bool {
        guard attachments.count <= maximumAttachmentCount else { return false }
        var total = 0
        for attachment in attachments {
            let bytes: Int
            switch attachment {
            case let .image(data, _, _): bytes = data.count
            case let .textFile(path, contents, name):
                bytes = path.lengthOfBytes(using: .utf8)
                    + contents.lengthOfBytes(using: .utf8)
                    + name.lengthOfBytes(using: .utf8)
            }
            guard bytes <= maximumAttachmentBytes - total else { return false }
            total += bytes
        }
        return true
    }

    private static func validateDatabaseLeaf(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw StoreError.database("transcript database path could not be inspected")
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw StoreError.database("transcript database path is not a regular file")
        }
    }

    private static func validateLegacyLeaf(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw StoreError.corruptLegacyArchive
        }
    }
}
