import Foundation
import ImageIO
import KaisolaCore
import SwiftUI
import UniformTypeIdentifiers

/// One rendered row in the chat transcript.
enum AcpTranscriptRow: Codable, Identifiable, Equatable, Sendable {
    /// `failed` marks an optimistic send whose prompt request errored — the row
    /// stays visible with a retry affordance instead of vanishing.
    case user(id: String, text: String, failed: Bool)
    case message(id: String, text: String)
    case thought(id: String, text: String)
    case tool(AcpToolCall)
    case plan(id: String, entries: [AcpPlanEntry])

    var id: String {
        switch self {
        case let .user(id, _, _): "user-\(id)"
        case let .message(id, _): "msg-\(id)"
        case let .thought(id, _): "thought-\(id)"
        case let .tool(call): "tool-\(call.id)"
        case let .plan(id, _): "plan-\(id)"
        }
    }
}

/// Reconciles user messages the ADAPTER reports against the ones the transcript
/// already holds, so a resumed session shows the user's own prompts exactly
/// once.
///
/// Both shipping adapters replay a loaded session's whole history as
/// `session/update` notifications, `user_message_chunk` included. Kaisola also
/// restores that same history from its own durable store, so without
/// reconciliation every restored prompt would appear twice. Two identities are
/// used, in order:
///
///  1. **The row id the store already keys on.** A replayed message the store
///     has never seen is appended under `acp:<adapterMessageId>`, so the NEXT
///     load recognizes its own earlier replay by id. Both adapters' message ids
///     come out of their persisted transcript, so they are stable across loads.
///  2. **Text, consumed one-for-one.** Rows this client wrote itself carry local
///     ids the adapter has never heard of, so the replay of a prompt Kaisola
///     sent can only be recognized by its text. Matching is a multiset take, not
///     a set membership test: sending "continue" three times leaves three rows
///     and absorbs exactly three replayed copies.
///
/// Pure and value-typed so both rules can be tested without an adapter.
struct AcpUserMessageLedger: Equatable, Sendable {
    /// Row-id prefix for a user row that came from an adapter rather than from
    /// this client. Kept inside the existing `.user(id:)` payload so the durable
    /// row shape — and every test that pins it — is unchanged.
    static let adapterIDPrefix = "acp:"

    enum Decision: Equatable, Sendable {
        /// The transcript already shows this message.
        case drop
        /// Append a new user row under this id.
        case append(id: String)
    }

    private var adapterIDs: Set<String> = []
    private var unmatchedTexts: [String: Int] = [:]
    private var generatedCounter = 0

    init(rows: [AcpTranscriptRow] = []) {
        for row in rows {
            guard case let .user(id, text, _) = row else { continue }
            if id.hasPrefix(Self.adapterIDPrefix) {
                adapterIDs.insert(id)
            }
            unmatchedTexts[text, default: 0] += 1
        }
    }

    /// Record a user row this client just wrote, so the adapter's replay of it
    /// is recognized. Claude echoes multi-block prompts (anything carrying an
    /// attachment) back live, and a later load replays every prompt, so this
    /// covers both.
    mutating func recordLocal(text: String) {
        unmatchedTexts[text, default: 0] += 1
    }

    mutating func reconcile(text: String, adapterMessageID: String?) -> Decision {
        if let adapterMessageID {
            let rowID = Self.adapterIDPrefix + adapterMessageID
            if adapterIDs.contains(rowID) { return .drop }
        }
        if let remaining = unmatchedTexts[text], remaining > 0 {
            if remaining == 1 {
                unmatchedTexts.removeValue(forKey: text)
            } else {
                unmatchedTexts[text] = remaining - 1
            }
            return .drop
        }
        let rowID: String
        if let adapterMessageID {
            rowID = Self.adapterIDPrefix + adapterMessageID
            adapterIDs.insert(rowID)
        } else {
            // An adapter that sends no message id (Codex's rollout-file
            // fallback) still needs a collision-free row id.
            generatedCounter += 1
            rowID = "\(Self.adapterIDPrefix)anon-\(generatedCounter)"
        }
        // Deliberately NOT recorded as an unmatched text: a history that really
        // does contain the same prompt twice must produce two rows, and rule 1
        // already stops a later load from replaying this one again.
        return .append(id: rowID)
    }
}

/// Drives one ACP agent conversation and accumulates its streaming turn into a
/// transcript the chat view renders. Owns the AcpClient; runs on the main actor
/// so published transcript mutations are UI-safe.
@MainActor
final class AcpConversation: ObservableObject {
    @Published private(set) var rows: [AcpTranscriptRow] = [] {
        didSet {
            contentVersion &+= 1
            if isApplyingPersistedPage {
                lastHistoryInsertionContentVersion = contentVersion
            } else {
                lastHistoryInsertionContentVersion = nil
                onTranscriptChanged?(rows, loadedRowStartOrdinal)
            }
        }
    }
    /// Durable notice that older saved rows were pruned by the per-chat disk
    /// quota. It survives relaunch and remains visible instead of making the
    /// retained tail look like the complete transcript.
    @Published private(set) var transcriptRetentionStatus: AcpTranscriptStore.RetentionStatus
    /// Remains non-healthy while the newest visible snapshot has not reached
    /// SQLite. Unlike a transient toast, the chat surface keeps this state in
    /// view until persistence succeeds or the chat is explicitly removed.
    @Published private(set) var transcriptPersistenceHealth: AcpTranscriptStore.PersistenceHealth = .healthy
    /// Advances for both appended rows and in-place streaming updates. Views
    /// must follow this rather than `rows.count`: an agent can stream thousands
    /// of chunks into one existing Markdown row without changing the count.
    @Published private(set) var contentVersion: UInt64 = 0
    /// Lets transcript views distinguish a prepended durable page from new live
    /// output. Page insertion has its own explicit anchor restoration and must
    /// never trigger the bottom-follow or "New output" path.
    private(set) var lastHistoryInsertionContentVersion: UInt64?
    @Published private(set) var isRunning = false
    @Published private(set) var isConnected = false
    @Published private(set) var isReconnecting = false
    @Published private(set) var usage: AcpUsage?
    @Published private(set) var models: [AcpSessionInfo.Model] = []
    @Published private(set) var currentModelID: String?
    @Published private(set) var modes: [AcpSessionInfo.Mode] = []
    @Published private(set) var currentModeID: String?
    @Published private(set) var configOptions: [AcpConfigOption] = []
    /// The one adapter-owned setting currently awaiting confirmation. Keeping
    /// the prior value visible until this clears prevents a rejected effort
    /// level from masquerading as the value the next prompt will use.
    @Published private(set) var pendingConfigOptionID: String?
    @Published private(set) var commands: [AcpCommand] = []
    /// Whether this adapter advertised `_session/steering` at `initialize`.
    /// Reset on every connect so a swapped agent can never inherit the previous
    /// one's answer.
    @Published private(set) var supportsSteering = false
    /// Queued messages whose `_session/steering` request is still in flight.
    /// The row stays queued (and un-removable) until the adapter answers, so a
    /// rejected injection cannot lose it and a double tap cannot send it twice.
    @Published private(set) var injectingQueuedIDs: Set<String> = []
    @Published var pendingPermission: AcpPermissionRequest?
    @Published private(set) var statusMessage: String?
    /// Follow-up messages typed while a turn was running; each dispatches when
    /// the preceding turn ends.
    @Published private(set) var queued: [QueuedMessage] = [] {
        didSet { onQueueChanged?(queued.map(\.text)) }
    }
    /// Files/images staged in the composer, shown as chips, sent as real ACP
    /// content blocks with the next immediate send and cleared then. Queued
    /// follow-ups never carry attachments (see `send`).
    @Published private(set) var pendingAttachments: [PendingAttachment] = [] {
        didSet { onAttachmentsChanged?(pendingAttachments.map(\.attachment)) }
    }
    /// Number of file attachments currently being classified/read off the main
    /// actor. Exposed so the composer can show a tiny, non-blocking progress
    /// indicator instead of freezing while Finder/iCloud materializes a file.
    @Published private(set) var preparingAttachmentCount = 0
    /// Adapter-issued identity used as a best-effort resume candidate after a
    /// native-app restart. The broker remains the authority for terminal
    /// durability; ACP capability negotiation decides whether this id can load.
    @Published private(set) var providerSessionID: String?

    /// Original text + attachment blocks for failed sends, keyed by the failed
    /// row's Identifiable id, so `retryFailed` can re-send the exact payload
    /// (attachments included) rather than a text-only prompt.
    private var failedSends: [String: (text: String, attachments: [AcpAttachment])] = [:]

    /// Streams client events to `consume` IN ORDER. The client fires its handler
    /// from an actor off the main thread; yielding into one AsyncStream (drained
    /// by a single MainActor task) preserves event order — spawning a separate
    /// `Task { @MainActor }` per event does not, so a `tool_call_update` could
    /// race ahead of its `tool_call`, or `turnEnded` ahead of the message chunks.
    private var eventContinuation: AsyncStream<AcpEvent>.Continuation?
    private var eventConsumerTask: Task<Void, Never>?
    /// Pre-turn working-tree snapshots (git stash create), restorable from the
    /// header. Present only when the workspace is a git repo with changes.
    @Published private(set) var checkpoints: [TurnCheckpoint] = []
    /// The chat view renders only the last `visibleLimit` loaded rows. Earlier
    /// SQLite pages are fetched only when the top boundary appears; already
    /// loaded rows remain in memory so expanding never discards an anchor.
    @Published var visibleLimit: Int = AcpConversation.defaultVisibleLimit
    @Published private(set) var unloadedEarlierRowCount = 0

    struct QueuedMessage: Identifiable, Equatable, Sendable {
        let id: String
        let text: String
    }

    /// One attachment staged in the composer, rendered as a chip until sent.
    struct PendingAttachment: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        /// SF Symbol for the chip's kind glyph (`photo` / `doc.text`).
        let iconName: String
        let byteSize: Int
        let attachment: AcpAttachment
    }

    struct TurnCheckpoint: Identifiable, Equatable, Sendable {
        let id: String       // stash commit hash
        let turn: Int
        let at: Date
    }

    @Published var title: String
    var workspaceURL: URL { URL(fileURLWithPath: cwd, isDirectory: true) }
    /// Reports needs-you moments (permission surfaced, turn finished) so the
    /// owner can decide whether they warrant an inbox entry. Set by AppModel.
    var onAttention: ((AttentionCenter.Kind, _ detail: String) -> Void)?
    /// Persistence hooks are injected by AppModel so this reusable conversation
    /// stays independent of the concrete disk stores used by the native shell.
    var onTranscriptChanged: ((_ rows: [AcpTranscriptRow], _ startOrdinal: Int64) -> Void)?
    var onRetryTranscriptPersistence: (() -> Void)?
    /// The owner writes a complete retained Markdown export from its transcript
    /// actor. Keeping the hook async means older pages never pass through this
    /// MainActor presentation model merely to reach disk.
    var onExportTranscriptMarkdown: ((
        _ request: AcpTranscriptMarkdownExport.Request,
        _ destination: URL
    ) async throws -> AcpTranscriptMarkdownExport.Receipt)?
    /// Bounded page loader injected by AppModel (or MeshSession) so this
    /// presentation model remains independent of the concrete SQLite store.
    var loadEarlierRows: ((_ beforeOrdinal: Int64, _ limit: Int) async -> AcpTranscriptStore.Page?)?
    /// Live ACP-declared locations/diff paths for explicit follow mode. This is
    /// never derived from transcript prose. Return true only after the owner
    /// resolves and accepts the target; a not-yet-created file can then retry
    /// on a later tool update.
    var onFileActivity: ((AcpFileActivity) -> Bool)?
    var onProviderSessionID: ((String) -> Void)?
    var onDraftChanged: ((String) -> Void)?
    var onAttachmentsChanged: (([AcpAttachment]) -> Void)?
    /// Pending follow-ups are part of the workspace recovery contract, not
    /// ephemeral view state. AppModel uses this hook to archive their exact
    /// FIFO order whenever the queue changes.
    var onQueueChanged: (([String]) -> Void)?
    /// Stable per-chat key for persisting the composer draft across relaunches.
    /// Set by the owner (AppModel passes the chat id) or the `draftKey` init
    /// parameter. Nil disables persistence: `loadDraft` returns "" and
    /// `saveDraft` is a no-op.
    var draftStorageKey: String?
    private var client: AcpClient
    /// Reconciles adapter-reported user messages against the rows already shown.
    private var userMessageLedger: AcpUserMessageLedger
    /// The adapter user message whose chunks are still arriving, and the row it
    /// opened — `nil` when the message was recognized as one already shown, in
    /// which case its remaining chunks stay suppressed too.
    private var streamingUserMessage: (adapterID: String, rowID: String?)?
    /// Streaming text collected since the last publish; see `bufferChunk`.
    private var pendingChunk: (text: String, isThought: Bool)?
    private var chunkFlushTask: Task<Void, Never>?

    /// How long buffered text waits before it reaches the transcript.
    ///
    /// Short enough to read as live typing (three frames at 60 Hz), long enough
    /// that a fast adapter's chunks collapse into one update instead of dozens.
    static let chunkFlushInterval: Duration = .milliseconds(50)
    private var reportedFileActivityKeys: Set<String> = []
    private var reportedFileActivityOrder: [String] = []
    private static let maximumReportedFileActivityKeys = 2_048
    /// Production conversations own their client and can replace it after the
    /// child process exits. Injected clients remain fixed so tests/custom
    /// transports never get silently swapped for a real process transport.
    private let ownsClient: Bool
    /// Produces a genuinely fresh client/transport for an app-owned restart.
    /// The injectable factory keeps crash recovery process-free in tests while
    /// preserving the rule that caller-owned clients are never replaced.
    private let clientFactory: @MainActor () -> AcpClient
    private let command: String
    private let arguments: [String]
    private let containment: CustomAdapterContainment?
    private let environment: [String: String]
    private let cwd: String
    private let transcriptAgentID: String
    private let transcriptAgentName: String?
    private let transcriptModelID: String?
    private let mcpServers: [JSONValue]
    private let ruleStore: PermissionRuleStore
    private let sensitiveGlobs: [String]
    private let resumeSessionID: String?
    private var restoredDraft: String?
    private(set) var loadedRowStartOrdinal: Int64 = 0
    private var isApplyingPersistedPage = false
    private var earlierPageLoadInFlight = false
    private var hasStarted = false
    private var turnCounter = 0
    /// Monotonic transcript segment identity. A single turn may emit
    /// message -> tool -> message (or thought -> tool -> thought); using only
    /// `turnCounter` gave those non-contiguous rows duplicate SwiftUI ids.
    private var segmentCounter = 0
    private var queueCounter = 0
    /// The prompt task is retained so restart can quiesce the old client before
    /// a queued follow-up is dispatched on its replacement. This closes the
    /// crash race where an old failure could otherwise mark a new turn idle.
    private var activePromptTask: Task<Void, Never>?
    private var activePromptTurn: Int?
    private var attachmentCounter = 0
    private var draftPersistenceTask: Task<Void, Never>?
    private var pendingDraftPersistence: String?
    /// Fences a late setting response after stop, restart, or adapter exit.
    private var configOptionRequestGeneration: UInt64 = 0
    /// Lets a later successful retry clear only the failure this setting path
    /// published, without erasing an unrelated turn or reconnect notice.
    private var lastConfigOptionFailureMessage: String?
    /// ACP adapters may issue several permission requests before the user has
    /// answered the first. Keep one visible request and preserve the remainder
    /// in arrival order instead of replacing the on-screen card.
    @Published private var permissionQueue: [AcpPermissionRequest] = []

    /// Default transcript render window: only the last 120 rows paint until the
    /// the user reaches the top. Each top crossing reveals `expandStep` more.
    static let defaultVisibleLimit = 120
    private static let expandStep = 200
    static let maxPendingAttachmentCount = 8
    static let maxPendingAttachmentBytes = 20 * 1_048_576

    init(
        title: String,
        command: String,
        arguments: [String],
        containment: CustomAdapterContainment? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cwd: String,
        transcriptAgentID: String = "unknown-agent",
        transcriptAgentName: String? = nil,
        transcriptModelID: String? = nil,
        mcpServers: [JSONValue] = [],
        client: AcpClient? = nil,
        clientFactory: (@MainActor () -> AcpClient)? = nil,
        ruleStore: PermissionRuleStore = PermissionRuleStore(),
        sensitiveGlobs: [String] = AcpPermissionRules.defaultSensitiveGlobs,
        draftKey: String? = nil,
        resumeSessionID: String? = nil,
        initialRows: [AcpTranscriptRow] = [],
        initialRowStartOrdinal: Int64 = 0,
        initialEarlierRowCount: Int = 0,
        initialTotalRowCount: Int? = nil,
        initialRetentionStatus: AcpTranscriptStore.RetentionStatus = .empty,
        initialDraft: String? = nil,
        initialAttachments: [AcpAttachment] = [],
        initialUsage: AcpUsage? = nil,
        initialQueuedPrompts: [String] = []
    ) {
        self.title = title
        self.command = command
        self.arguments = arguments
        self.containment = containment
        self.environment = environment
        self.cwd = cwd
        self.transcriptAgentID = transcriptAgentID
        self.transcriptAgentName = transcriptAgentName
        self.transcriptModelID = transcriptModelID
        self.mcpServers = mcpServers
        let factory = clientFactory ?? { AcpClient() }
        self.clientFactory = factory
        self.client = client ?? factory()
        self.ownsClient = client == nil
        self.ruleStore = ruleStore
        self.sensitiveGlobs = sensitiveGlobs
        self.draftStorageKey = draftKey
        self.resumeSessionID = resumeSessionID
        self.rows = initialRows
        self.userMessageLedger = AcpUserMessageLedger(rows: initialRows)
        self.loadedRowStartOrdinal = max(0, initialRowStartOrdinal)
        self.unloadedEarlierRowCount = max(0, initialEarlierRowCount)
        self.transcriptRetentionStatus = initialRetentionStatus
        self.restoredDraft = initialDraft
        self.pendingAttachments = Self.restoredPendingAttachments(initialAttachments)
        self.attachmentCounter = self.pendingAttachments.count
        self.usage = initialUsage
        self.queued = initialQueuedPrompts.enumerated().map { index, text in
            QueuedMessage(id: "q\(index + 1)", text: text)
        }
        self.queueCounter = initialQueuedPrompts.count
        let loadedTurnCount = initialRows.reduce(into: 0) { count, row in
            if case .user = row { count += 1 }
        }
        let durableRowCount = max(initialRows.count, initialTotalRowCount ?? initialRows.count)
        // A tail-only restore cannot count every historic user turn. Starting
        // both monotonic identifiers at or above the durable row count may skip
        // integers, but it can never collide with a retained row identifier.
        self.turnCounter = max(loadedTurnCount, durableRowCount)
        self.segmentCounter = durableRowCount
    }

    func start(resumeQueuedPrompts: Bool = false) async {
        guard !hasStarted else { return }
        hasStarted = true
        invalidateConfigOptionRequest()
        // One ordered pipe from the client's (off-main) event handler to the
        // MainActor consumer: yields preserve order, and a single draining task
        // consumes them serially. The handler captures the continuation (not
        // self) so it stays Sendable without touching main-actor state.
        let (stream, continuation) = AsyncStream<AcpEvent>.makeStream(bufferingPolicy: .unbounded)
        eventContinuation = continuation
        eventConsumerTask = Task { @MainActor [weak self] in
            for await event in stream { self?.consume(event) }
        }
        await client.setEventHandler { event in
            continuation.yield(event)
        }
        await client.configureFsGuard(sensitiveGlobs: sensitiveGlobs)
        do {
            let launch = try containment.map {
                try $0.prepare(environment: environment, cwd: cwd)
            } ?? AcpAdapterLaunch(
                command: command,
                arguments: arguments,
                environment: environment,
                cwd: cwd,
                access: .unrestricted,
                sandboxProfile: nil
            )
            let info = try await client.start(
                command: launch.command,
                arguments: launch.arguments,
                environment: launch.environment,
                cwd: launch.cwd,
                mcpServers: mcpServers,
                resumeSessionID: providerSessionID ?? resumeSessionID,
                access: launch.access
            )
            providerSessionID = info.sessionID
            onProviderSessionID?(info.sessionID)
            models = info.models
            currentModelID = info.currentModelID
            modes = info.modes
            currentModeID = info.currentModeID
            configOptions = info.configOptions
            supportsSteering = info.supportsSteering
            isConnected = true
            statusMessage = nil
            lastConfigOptionFailureMessage = nil
            // Only entries still in `queued` are known never to have been
            // dispatched. An explicit adapter restart resumes them; ordinary
            // app restoration leaves them paused until the user chooses Resume
            // All, avoiding surprise work immediately after launch.
            if resumeQueuedPrompts { flushQueue() }
        } catch {
            hasStarted = false
            eventContinuation?.finish()
            eventContinuation = nil
            eventConsumerTask?.cancel()
            eventConsumerTask = nil
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isConnected = false
            supportsSteering = false
        }
    }

    var canRestart: Bool {
        ownsClient && !isConnected && !isRunning && !isReconnecting
    }

    /// Restart an app-owned adapter with a fresh transport. Reusing the dead
    /// `Process` object is intentionally avoided; the provider session id is
    /// offered back through ACP load/resume negotiation when supported.
    func restart() async {
        guard canRestart else { return }
        invalidateConfigOptionRequest()
        isReconnecting = true
        statusMessage = "Restarting agent…"
        eventContinuation?.finish()
        eventContinuation = nil
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
        let oldClient = client
        let oldPromptTask = activePromptTask
        await oldClient.stop()
        await oldPromptTask?.value
        client = clientFactory()
        hasStarted = false
        await start(resumeQueuedPrompts: true)
        isReconnecting = false
    }

    /// Send a message, or — if a turn is already running — queue it as a
    /// follow-up that dispatches automatically when the current turn ends.
    /// Any staged attachments ride the immediate send and are cleared; a send
    /// with attachments alone (no text) is allowed when idle.
    @discardableResult
    func send(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments.map(\.attachment)
        guard isConnected, !trimmed.isEmpty || !attachments.isEmpty else { return false }
        if isRunning {
            // A running turn queues this as a TEXT-ONLY follow-up. Queued
            // follow-ups deliberately never carry attachments (the flush path
            // dispatches with none), so the staged chips stay put and ride the
            // next immediate send. An attachments-only send can't be queued.
            guard !trimmed.isEmpty else { return false }
            queueCounter += 1
            queued.append(QueuedMessage(id: "q\(queueCounter)", text: trimmed))
            return true
        }
        pendingAttachments.removeAll()
        dispatch(trimmed, attachments: attachments)
        return true
    }

    /// Drop a still-pending queued follow-up before it dispatches. A message
    /// whose injection is in flight is left alone: the adapter may already have
    /// taken it, and removing it here would hide a message that is about to
    /// speak.
    func removeQueued(_ id: String) {
        guard !injectingQueuedIDs.contains(id) else { return }
        queued.removeAll { $0.id == id }
    }

    /// Resume a restored/paused FIFO. Dispatch removes exactly one item; the
    /// normal turn-end path advances the remainder one at a time.
    func resumeQueuedFollowUps() {
        flushQueue()
    }

    /// Whether a queued row may offer the inject action right now. Sending
    /// mid-turn still queues — this is the per-message escape hatch, and it is
    /// offered only when it can actually work.
    var canInjectQueued: Bool {
        AcpSteering.canInject(
            supportsSteering: supportsSteering,
            isConnected: isConnected,
            isRunning: isRunning
        )
    }

    /// Steer: inject ONE queued follow-up into the turn that is running, via
    /// `_session/steering`. The message stays queued for the whole round trip
    /// and leaves the queue only once the adapter says it took it, so a refusal
    /// or a turn that ended first can never lose it.
    func injectQueued(_ id: String) {
        guard canInjectQueued,
              !injectingQueuedIDs.contains(id),
              let message = queued.first(where: { $0.id == id }) else { return }
        injectingQueuedIDs.insert(id)
        let steerClient = client
        Task { [weak self] in
            let outcome = await steerClient.steer(message.text)
            self?.applySteerOutcome(outcome, for: message)
        }
    }

    private func applySteerOutcome(_ outcome: AcpSteerOutcome, for message: QueuedMessage) {
        injectingQueuedIDs.remove(message.id)
        switch AcpSteering.decide(outcome) {
        case .delivered:
            queued.removeAll { $0.id == message.id }
            appendInjectedUserRow(message.text)
        case let .deliveredAsNewTurn(notice):
            queued.removeAll { $0.id == message.id }
            appendInjectedUserRow(message.text)
            statusMessage = notice
            ToastCenter.shared.show(notice, style: .info)
        case let .keptQueued(notice):
            // Left exactly where it was. `turnEnded` still flushes the queue in
            // the ordinary way, so a message the adapter would not inject is
            // sent as its own turn rather than dropped.
            statusMessage = notice
            ToastCenter.shared.show(notice, style: .error)
        }
        // The turn may have ended while the request was in flight, with the
        // ordinary flush held back for exactly this message.
        flushQueue()
    }

    /// Show an injected message in the transcript at the point in the turn where
    /// it landed. Neither adapter echoes an injected message back — Claude's
    /// consumer drops the echo as an unrelated replay, and Codex never surfaces
    /// live user items — so the row has to be written here. The ledger records
    /// it so a LATER `session/load` replay of the same message is recognized
    /// rather than shown a second time.
    private func appendInjectedUserRow(_ text: String) {
        turnCounter += 1
        rows.append(.user(id: "\(turnCounter)", text: text, failed: false))
        userMessageLedger.recordLocal(text: text)
    }

    /// Retry a failed optimistic send: the failed row is replaced by a fresh
    /// dispatch of the SAME text AND attachments. A failed send stashes its
    /// original (pre-📎-label) text and attachment blocks under the row id, so
    /// retry re-sends the image/file bytes faithfully instead of a text-only
    /// prompt. (A retry while another turn runs falls back to a text-only queued
    /// follow-up — the queue is text-only by design.)
    func retryFailed(_ rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }),
              case let .user(_, text, failed) = rows[index], failed else { return }
        rows.remove(at: index)
        let stashed = failedSends.removeValue(forKey: rowID)
        let originalText = stashed?.text ?? text
        let attachments = stashed?.attachments ?? []
        if isRunning {
            guard !originalText.isEmpty else { return }
            queueCounter += 1
            queued.append(QueuedMessage(id: "q\(queueCounter)", text: originalText))
        } else {
            dispatch(originalText, attachments: attachments)
        }
    }

    // MARK: - Attachments

    /// Classify a dropped/opened file and, when accepted, stage it as a pending
    /// chip; rejects (wrong kind, too large, non-UTF-8 text) surface a toast.
    func addAttachment(fileURL: URL) {
        switch AcpAttachmentClassifier.classify(fileURL: fileURL) {
        case let .accepted(attachment): appendPending(attachment)
        case let .rejected(reason): ToastCenter.shared.show(reason, style: .error)
        }
    }

    /// UI attachment path. Filesystem metadata, cloud-file materialization, and
    /// bounded file reads all happen away from MainActor. The synchronous
    /// classifier remains available for deterministic unit tests.
    func prepareAttachment(fileURL: URL) {
        guard pendingAttachments.count + preparingAttachmentCount < Self.maxPendingAttachmentCount else {
            ToastCenter.shared.show("Attach up to \(Self.maxPendingAttachmentCount) files per message.", style: .info)
            return
        }
        preparingAttachmentCount += 1
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                AcpAttachmentClassifier.classify(fileURL: fileURL)
            }.value
            guard let self else { return }
            self.preparingAttachmentCount = max(0, self.preparingAttachmentCount - 1)
            switch outcome {
            case let .accepted(attachment): self.appendPending(attachment)
            case let .rejected(reason): ToastCenter.shared.show(reason, style: .error)
            }
        }
    }

    /// Stage raw image bytes from the pasteboard (already normalized to PNG).
    /// Oversized but bounded sources downscale away from MainActor using the
    /// same ImageIO path as file attachments.
    func addImageData(_ data: Data, name: String) {
        if data.count <= AcpAttachmentClassifier.maxImageBytes {
            appendPending(.image(data: data, mimeType: "image/png", name: name))
            return
        }
        guard data.count <= AcpImageDownscaler.maximumSourceBytes else {
            ToastCenter.shared.show("\(name) is too large to downscale safely.", style: .error)
            return
        }
        guard pendingAttachments.count + preparingAttachmentCount < Self.maxPendingAttachmentCount else {
            ToastCenter.shared.show("Attach up to \(Self.maxPendingAttachmentCount) files per message.", style: .info)
            return
        }

        preparingAttachmentCount += 1
        Task { [weak self] in
            let scaled = await Task.detached(priority: .userInitiated) {
                AcpImageDownscaler.downscale(
                    data: data,
                    maximumBytes: AcpAttachmentClassifier.maxImageBytes
                )
            }.value
            guard let self else { return }
            self.preparingAttachmentCount = max(0, self.preparingAttachmentCount - 1)
            guard let scaled else {
                ToastCenter.shared.show(
                    "\(name) could not be downscaled safely below 5 MB.",
                    style: .error
                )
                return
            }
            self.appendPending(.image(
                data: scaled.data,
                mimeType: scaled.mimeType,
                name: name
            ))
        }
    }

    /// Drop a staged attachment chip before it is sent.
    func removeAttachment(_ id: String) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// Append a classified attachment as a pending chip, deduping an identical
    /// payload so the same file added twice shows once.
    private func appendPending(_ attachment: AcpAttachment) {
        guard !pendingAttachments.contains(where: { $0.attachment == attachment }) else { return }
        let (icon, size) = Self.attachmentPresentation(attachment)
        guard pendingAttachments.count < Self.maxPendingAttachmentCount else {
            ToastCenter.shared.show("Attach up to \(Self.maxPendingAttachmentCount) files per message.", style: .info)
            return
        }
        let stagedBytes = pendingAttachments.reduce(0) { $0 + $1.byteSize }
        guard stagedBytes + size <= Self.maxPendingAttachmentBytes else {
            ToastCenter.shared.show("Attachments are limited to 20 MB per message.", style: .error)
            return
        }
        attachmentCounter += 1
        pendingAttachments.append(PendingAttachment(
            id: "att\(attachmentCounter)", name: attachment.name,
            iconName: icon, byteSize: size, attachment: attachment
        ))
    }

    /// Rebuild composer chips from the durable bounded attachment list. A
    /// malformed future payload is filtered again at the UI boundary so it can
    /// never bypass the same count/aggregate limits as a fresh Finder drop.
    private static func restoredPendingAttachments(
        _ attachments: [AcpAttachment]
    ) -> [PendingAttachment] {
        var result: [PendingAttachment] = []
        var totalBytes = 0
        for attachment in attachments {
            guard result.count < maxPendingAttachmentCount,
                  !result.contains(where: { $0.attachment == attachment }) else { continue }
            let (icon, size) = attachmentPresentation(attachment)
            guard size <= maxPendingAttachmentBytes - totalBytes else { continue }
            totalBytes += size
            result.append(PendingAttachment(
                id: "att\(result.count + 1)",
                name: attachment.name,
                iconName: icon,
                byteSize: size,
                attachment: attachment
            ))
        }
        return result
    }

    private static func attachmentPresentation(_ attachment: AcpAttachment) -> (String, Int) {
        switch attachment {
        case let .image(data, _, _): ("photo", data.count)
        case let .textFile(_, contents, _): ("doc.text", contents.utf8.count)
        }
    }

    /// Compose the user-visible (and prompt) text: the typed text plus a
    /// trailing "📎 name1, name2" line naming any attachments. The
    /// AcpTranscriptRow shape is unchanged — the names live inside the existing
    /// `.user` text so the tests that pin the row cases keep passing. `nonisolated`
    /// because it is pure (no actor state) and is exercised off the main actor.
    nonisolated static func userText(_ text: String, attachments: [AcpAttachment]) -> String {
        guard !attachments.isEmpty else { return text }
        let label = attachments.map(\.name).joined(separator: ", ")
        if text.isEmpty { return "📎 " + label }
        return text + "\n📎 " + label
    }

    private func dispatch(_ trimmed: String, attachments: [AcpAttachment] = []) {
        turnCounter += 1
        statusMessage = nil
        // Keep any history the user has already revealed. The view independently
        // follows live output only while its bottom sentinel remains visible.
        let rowID = "\(turnCounter)"
        let turn = turnCounter
        let displayText = Self.userText(trimmed, attachments: attachments)
        rows.append(.user(id: rowID, text: displayText, failed: false))
        // Claude echoes any prompt carrying more than one content block (i.e.
        // every attachment send) straight back as `user_message_chunk`, and a
        // later `session/load` replays all of them. Record it so neither shows
        // up as a second copy of what the user just typed.
        userMessageLedger.recordLocal(text: displayText)
        isRunning = true
        let dispatchClient = client
        activePromptTurn = turn
        activePromptTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activePromptTurn == turn {
                    self.activePromptTurn = nil
                    self.activePromptTask = nil
                }
            }
            // The snapshot must complete BEFORE the agent starts, or it could
            // capture partial agent edits instead of the pre-turn tree.
            await recordCheckpoint(turn: turn)
            do { try await dispatchClient.prompt(displayText, attachments: attachments) }
            catch {
                statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                isRunning = false
                // Roll back optimism: mark the row failed so the user can retry.
                // Stash the ORIGINAL text + attachment blocks (keyed by the row's
                // Identifiable id) so Retry re-sends them faithfully.
                if let index = rows.firstIndex(where: { $0.id == "user-\(rowID)" }) {
                    rows[index] = .user(id: rowID, text: displayText, failed: true)
                    failedSends["user-\(rowID)"] = (text: trimmed, attachments: attachments)
                }
            }
        }
    }

    func cancel() {
        pendingPermission = nil
        permissionQueue.removeAll()
        Task { await client.cancel() }
    }

    func selectModel(_ id: String) {
        currentModelID = id
        Task { await client.setModel(id) }
    }

    func selectMode(_ id: String) {
        currentModeID = id
        Task { await client.setMode(id) }
    }

    /// Set an adapter config option (effort level etc.) transactionally.
    ///
    /// The adapter's last confirmed value remains on screen while the request
    /// is in flight. Only the returned option set may replace it; a rejection
    /// leaves the draft, transcript, running turn, and confirmed value intact.
    /// One request at a time also makes response order unambiguous.
    func selectConfigOption(_ id: String, value: String) {
        guard isConnected, pendingConfigOptionID == nil,
              let option = configOptions.first(where: { $0.id == id }),
              option.currentValue != value,
              let choice = option.choices.first(where: { $0.value == value }) else { return }

        configOptionRequestGeneration &+= 1
        let generation = configOptionRequestGeneration
        pendingConfigOptionID = id
        let requestClient = client
        Task { [weak self] in
            do {
                let confirmed = try await requestClient.setConfigOption(id: id, value: value)
                guard let self, self.configOptionRequestGeneration == generation else { return }
                self.pendingConfigOptionID = nil
                self.configOptions = confirmed
                if self.statusMessage == self.lastConfigOptionFailureMessage {
                    self.statusMessage = nil
                }
                self.lastConfigOptionFailureMessage = nil
            } catch {
                guard let self, self.configOptionRequestGeneration == generation else { return }
                self.pendingConfigOptionID = nil
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let message = "Couldn’t change \(option.name) to \(choice.name). \(detail)"
                self.lastConfigOptionFailureMessage = message
                self.statusMessage = message
            }
        }
    }

    private func invalidateConfigOptionRequest() {
        configOptionRequestGeneration &+= 1
        pendingConfigOptionID = nil
    }

    func answerPermission(_ optionID: String) {
        guard let permission = pendingPermission else { return }
        pendingPermission = nil
        Task { await client.resolvePermission(id: permission.id, optionID: optionID) }
        presentNextPermission()
    }

    /// Deny once when the adapter exposes that exact option. If it does not,
    /// return ACP's non-persistent cancelled outcome rather than accidentally
    /// selecting an opaque `reject_always` choice.
    func denyPermission() {
        guard let permission = pendingPermission else { return }
        if let option = permission.denyOnceOption {
            answerPermission(option.id)
            return
        }
        pendingPermission = nil
        Task { await client.cancelPermission(id: permission.id) }
        presentNextPermission()
    }

    /// Select only an exact one-time allow. Adapter-owned `allow_always`
    /// choices are deliberately excluded because their scope is not inspectable.
    func allowPermissionOnce() {
        guard let option = pendingPermission?.allowOnceOption else { return }
        answerPermission(option.id)
    }

    /// Grant this ask AND create a standing rule so future matching asks
    /// auto-allow. Refused for sensitive-file asks and adapters without an exact
    /// one-time allow; the disabled UI is backed by this defense in depth.
    func answerPermissionAlways() {
        guard let review = pendingPermissionReview,
              let allowOnceOptionID = review.allowOnceOptionID,
              pendingPermissionAllowsRule else { return }
        let rule = PermissionRule(
            id: UUID().uuidString,
            workspace: review.ruleScope.workspace,
            action: review.ruleScope.action,
            resource: review.ruleScope.resource,
            at: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        _ = ruleStore.add(rule)
        answerPermission(allowOnceOptionID)
    }

    /// Route an incoming permission ask: sensitive files always surface a card;
    /// otherwise a matching standing rule auto-allows silently; else surface.
    private func handlePermission(_ request: AcpPermissionRequest) {
        if AcpPermissionRules.requestIsSensitive(
            globs: sensitiveGlobs,
            title: request.title,
            paths: request.paths,
            rawInput: request.rawInput
        ) {
            enqueuePresentedPermission(request)
            return
        }
        if AcpPermissionRules.requestMatchesRule(
            ruleStore.rules(),
            workspace: cwd,
            kind: request.kind,
            resource: request.ruleMatchValue
        ) != nil,
           answerAllowOnce(request) {
            return
        }
        enqueuePresentedPermission(request)
    }

    private func enqueuePresentedPermission(_ request: AcpPermissionRequest) {
        guard pendingPermission?.id != request.id,
              !permissionQueue.contains(where: { $0.id == request.id }) else { return }
        guard pendingPermission == nil else {
            permissionQueue.append(request)
            return
        }
        pendingPermission = request
        onAttention?(.permission, request.title)
    }

    private func presentNextPermission() {
        guard pendingPermission == nil, !permissionQueue.isEmpty else { return }
        let next = permissionQueue.removeFirst()
        pendingPermission = next
        onAttention?(.permission, next.title)
    }

    /// Answer only with the request's exact `allow_once` option. A matching
    /// local rule must never silently escalate into adapter-owned persistence.
    @discardableResult
    private func answerAllowOnce(_ request: AcpPermissionRequest) -> Bool {
        guard let option = request.allowOnceOption else { return false }
        let wasPresented = pendingPermission?.id == request.id
        if wasPresented { pendingPermission = nil }
        Task { await client.resolvePermission(id: request.id, optionID: option.id) }
        if wasPresented { presentNextPermission() }
        return true
    }

    var pendingPermissionReview: AcpPermissionReview? {
        pendingPermission.map { AcpPermissionReview(request: $0, workspace: cwd) }
    }

    /// Whether the pending ask may create a reviewed standing rule. Sensitive
    /// requests and adapters without an exact one-time allow remain prompt-only.
    var pendingPermissionAllowsRule: Bool {
        guard let permission = pendingPermission else { return false }
        guard permission.allowOnceOption != nil else { return false }
        return !AcpPermissionRules.requestIsSensitive(
            globs: sensitiveGlobs,
            title: permission.title,
            paths: permission.paths,
            rawInput: permission.rawInput
        )
    }

    var pendingPermissionCount: Int {
        (pendingPermission == nil ? 0 : 1) + permissionQueue.count
    }

    /// Stop the adapter and every terminal host it owns. Returning the final
    /// debounced composer value lets the window owner durably save it before
    /// AppKit receives the quit reply.
    func stop() async -> String? {
        invalidateConfigOptionRequest()
        draftPersistenceTask?.cancel()
        draftPersistenceTask = nil
        let finalDraft = pendingDraftPersistence
        pendingDraftPersistence = nil
        await client.stop()
        flushPendingChunk()
        isConnected = false
        isRunning = false
        supportsSteering = false
        injectingQueuedIDs.removeAll()
        statusMessage = queued.isEmpty
            ? "The agent is stopped."
            : "The agent is stopped. \(queued.count) queued follow-up\(queued.count == 1 ? " is" : "s are") ready to resume."
        pendingPermission = nil
        permissionQueue.removeAll()
        eventContinuation?.finish()
        eventContinuation = nil
        let consumer = eventConsumerTask
        eventConsumerTask = nil
        await consumer?.value
        return finalDraft
    }

    /// Live output of an agent-spawned terminal, for tool-card rendering.
    func terminalSnapshot(_ id: String) async -> AcpTerminalHost.Snapshot? {
        await client.terminalSnapshot(id)
    }

    // MARK: - Pre-turn checkpoints

    /// Snapshot the working tree before the agent's turn starts (awaited by
    /// the dispatch path so the agent cannot race the snapshot). A non-repo or
    /// clean tree is silently skipped — a clean tree's restore point is HEAD.
    /// Snapshots cover TRACKED files (git stash create semantics).
    private func recordCheckpoint(turn: Int) async {
        let workspace = cwd
        let hash = await Task.detached(priority: .userInitiated) { () -> String? in
            let service = GitService(repoRoot: URL(fileURLWithPath: workspace, isDirectory: true))
            return try? service.checkpoint()
        }.value
        guard let hash else { return }
        checkpoints.append(TurnCheckpoint(id: hash, turn: turn, at: Date()))
        if checkpoints.count > 20 {
            let dropped = checkpoints.removeFirst()
            dropCheckpointRef(dropped.id)
        }
    }

    /// Release a checkpoint's keep-alive ref once it ages out of the menu.
    private func dropCheckpointRef(_ hash: String) {
        let workspace = cwd
        Task.detached(priority: .utility) {
            let service = GitService(repoRoot: URL(fileURLWithPath: workspace, isDirectory: true))
            try? service.dropCheckpoint(hash)
        }
    }

    /// Restore a checkpoint's files over the current tree (user-confirmed in
    /// the header). Conflicts surface as a status message, never silently.
    func restoreCheckpoint(_ id: String) {
        let workspace = cwd
        Task.detached(priority: .userInitiated) { [weak self] in
            let service = GitService(repoRoot: URL(fileURLWithPath: workspace, isDirectory: true))
            let outcome: Result<Void, any Error>
            do {
                try service.applyCheckpoint(id)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { [weak self] in
                switch outcome {
                case .success:
                    ToastCenter.shared.show("Checkpoint restored.", style: .success)
                case let .failure(error):
                    self?.statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    // MARK: - Transcript paging

    /// The tail of the currently loaded pages that the chat view renders.
    /// SQLite rows before `loadedRowStartOrdinal` are not allocated until the
    /// user reaches the top boundary.
    var visibleRows: [AcpTranscriptRow] {
        rows.count > visibleLimit ? Array(rows.suffix(visibleLimit)) : rows
    }

    /// Exact earlier-row count across both loaded-but-hidden and unloaded pages.
    var hiddenEarlierCount: Int {
        max(0, rows.count - visibleLimit) + unloadedEarlierRowCount
    }

    /// Reveal an already loaded window or fetch one bounded page immediately
    /// before it. Page insertion deliberately suppresses the persistence hook:
    /// those rows already came from the durable store and only the UI window
    /// changed. `contentVersion` still advances so the view restores its anchor.
    func expandEarlier() async {
        if rows.count > visibleLimit {
            visibleLimit = min(rows.count, visibleLimit + Self.expandStep)
            return
        }
        guard unloadedEarlierRowCount > 0,
              !earlierPageLoadInFlight,
              let loadEarlierRows else { return }

        let boundary = loadedRowStartOrdinal
        earlierPageLoadInFlight = true
        defer { earlierPageLoadInFlight = false }
        guard let page = await loadEarlierRows(boundary, Self.expandStep),
              loadedRowStartOrdinal == boundary else { return }
        guard !page.rows.isEmpty else {
            unloadedEarlierRowCount = 0
            return
        }
        guard page.startOrdinal >= 0,
              page.endOrdinalExclusive == boundary else { return }

        isApplyingPersistedPage = true
        loadedRowStartOrdinal = page.startOrdinal
        unloadedEarlierRowCount = max(0, page.earlierRowCount)
        rows.insert(contentsOf: page.rows, at: 0)
        isApplyingPersistedPage = false
        visibleLimit = min(rows.count, visibleLimit + page.rows.count)
    }

    // MARK: - Persistent draft

    /// Preference keys written by the original composer persistence path.
    /// Keep the list centralized so permanent deletion can clear every
    /// source-backed alias without scanning or disturbing unrelated defaults.
    static func persistedDraftDefaultsKeys(for draftStorageKey: String) -> [String] {
        ["chatDraft.\(draftStorageKey)"]
    }

    static func removePersistedDraft(
        for draftStorageKey: String,
        currentDefaults: UserDefaults = .standard,
        migratedDefaults: UserDefaults? = UserDefaults(
            suiteName: KaisolaProductMigration.legacyBundleIdentifier
        )
    ) {
        for key in persistedDraftDefaultsKeys(for: draftStorageKey) {
            currentDefaults.removeObject(forKey: key)
            migratedDefaults?.removeObject(forKey: key)
        }
    }

    private var draftDefaultsKey: String? {
        draftStorageKey.flatMap { Self.persistedDraftDefaultsKeys(for: $0).first }
    }

    /// The composer draft persisted for this chat, or "" when none exists or the
    /// chat is unkeyed.
    func loadDraft() -> String {
        if let restoredDraft {
            self.restoredDraft = nil
            return restoredDraft
        }
        guard let key = draftDefaultsKey else { return "" }
        return UserDefaults.standard.string(forKey: key) ?? ""
    }

    /// Persist the composer draft for this chat, or clear it (remove the key)
    /// when empty. No-op for an unkeyed chat.
    func saveDraft(_ text: String) {
        guard let key = draftDefaultsKey else { return }
        if text.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(text, forKey: key)
        }
        pendingDraftPersistence = text
        draftPersistenceTask?.cancel()
        draftPersistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self,
                  let pending = self.pendingDraftPersistence else { return }
            self.pendingDraftPersistence = nil
            self.onDraftChanged?(pending)
        }
    }

    /// The latest visible assistant prose, deliberately excluding thought,
    /// tool, and plan rows that may follow it. The restored tail always contains
    /// the end of the conversation, so this remains bounded for paged chats.
    var lastAssistantResponse: String? {
        AcpTranscriptMarkdownExport.lastAssistantResponse(in: rows)
    }

    func exportTranscriptMarkdown(
        to destination: URL,
        exportedAt: Date = Date()
    ) async throws -> AcpTranscriptMarkdownExport.Receipt {
        guard let onExportTranscriptMarkdown else {
            throw AcpTranscriptStore.StoreError.database("Transcript export is unavailable")
        }
        let modelID = currentModelID ?? transcriptModelID
        return try await onExportTranscriptMarkdown(
            AcpTranscriptMarkdownExport.Request(
                title: title,
                agentID: transcriptAgentID,
                agentName: transcriptAgentName,
                modelID: modelID,
                exportedAt: exportedAt
            ),
            destination
        )
    }

    // MARK: - Test hooks

    /// Test-only: replace the transcript wholesale so paging math can be
    /// exercised without driving a live turn. Not called by production code.
    func seedRowsForTesting(_ newRows: [AcpTranscriptRow]) {
        loadedRowStartOrdinal = 0
        unloadedEarlierRowCount = 0
        rows = newRows
    }

    func applyTranscriptPersistenceHealth(_ health: AcpTranscriptStore.PersistenceHealth) {
        transcriptPersistenceHealth = health
    }

    func retryTranscriptPersistence() {
        onRetryTranscriptPersistence?()
    }

    /// Test-only: seed the never-dispatched recovery FIFO without spawning an
    /// adapter or manufacturing an artificial running turn.
    func seedQueuedPromptsForTesting(_ prompts: [String]) {
        queued = prompts.enumerated().map { index, text in
            QueuedMessage(id: "q\(index + 1)", text: text)
        }
        queueCounter = prompts.count
    }

    /// Test seam for the FIFO presentation policy. Wire parsing remains covered
    /// separately by `AcpClientTests`; this exercises the UI-facing queue without
    /// spawning an adapter.
    func receivePermissionForTesting(_ request: AcpPermissionRequest) {
        handlePermission(request)
    }

    /// Test seam for transcript segmentation. The JSON-RPC decoder and event
    /// stream ordering have their own coverage; this lets a focused unit test
    /// prove that message -> tool -> message produces three distinct row ids
    /// and that in-place chunks advance `contentVersion`.
    func receiveTurnItemForTesting(_ item: AcpTurnItem) {
        accumulate(item)
    }

    /// Deterministic, process-free state for hosted/local visual inspection.
    /// Marking startup complete prevents the embedded view from launching a
    /// real provider while the fixture is being captured.
    func loadVisualFixture(includePermission: Bool = false) {
        hasStarted = true
        isConnected = true
        models = [
            AcpSessionInfo.Model(id: "sonnet", name: "Sonnet 4.5"),
            AcpSessionInfo.Model(id: "opus", name: "Opus 4.1"),
        ]
        currentModelID = "sonnet"
        modes = [
            AcpSessionInfo.Mode(id: "default", name: "Ask"),
            AcpSessionInfo.Mode(id: "bypass", name: "Bypass permissions"),
        ]
        currentModeID = "default"
        rows = [
            .user(id: "1", text: "Make the native project feel calm and fast.", failed: false),
            .message(id: "1", text: """
            ## Review ready

            | Check | Result |
            | --- | --- |
            | Focused tests | Passed |
            | Native build | Passed |

            ```swift
            let renderer = TranscriptRenderer(cache: .incremental)
            ```

            Inspect PR 8 in `PULL_REQUEST_FEATURES.md` for the exact acceptance contract.
            """),
            .tool(AcpToolCall(
                id: "visual-tool",
                title: "Inspect native project",
                kind: "read",
                status: .completed,
                content: [.text("Build and focused tests passed.")]
            )),
        ]
        usage = AcpUsage(
            used: 18_400,
            max: 200_000,
            costAmount: 0.42,
            costCurrency: "USD"
        )
        if includePermission {
            receivePermissionForTesting(AcpPermissionRequest(
                id: 1,
                sessionID: "visual-session",
                title: "Run the release verification commands",
                options: [
                    .init(id: "allow-once", name: "Allow once", kind: "allow_once"),
                    .init(id: "reject-once", name: "Reject once", kind: "reject_once"),
                    .init(id: "allow-always", name: "Always allow", kind: "allow_always"),
                ],
                rawInput: .object([
                    "command": .string("npm run native:test:changed && npm run native:fast -- --build-only"),
                    "cwd": .string(cwd),
                ]),
                kind: "execute",
                paths: [
                    "native/KaisolaMac/Kaisola/Acp/AcpChatView.swift",
                    "native/KaisolaMac/Kaisola/Acp/AcpConversation.swift",
                    "native/KaisolaMac/KaisolaTests/AcpPermissionRulesTests.swift",
                ]
            ))
        }
    }

    // MARK: - Stream accumulation

    private func consume(_ event: AcpEvent) {
        switch event {
        case let .turnItem(item):
            accumulate(item)
        case let .toolCallUpdate(id, status, content, locations, title):
            if let index = rows.lastIndex(where: { if case let .tool(c) = $0 { return c.id == id } else { return false } }),
               case var .tool(call) = rows[index] {
                if let status { call.status = status }
                if let content, !content.isEmpty { call.content = content }
                if let locations { call.locations = locations }
                if let title, !title.isEmpty { call.title = title }
                rows[index] = .tool(call)
                publishFileActivity(for: call)
            }
        case let .usage(usage):
            self.usage = usage
        case let .modelChanged(id):
            currentModelID = id
        case let .modeChanged(id):
            currentModeID = id
        case let .commands(list):
            commands = list
        case let .configOptions(options):
            configOptions = options
        case let .permission(request):
            handlePermission(request)
        case .turnEnded:
            // The turn's last words must be on screen before it reads as over.
            flushPendingChunk()
            isRunning = false
            onAttention?(.turnCompleted, "Finished a turn")
            flushQueue()
        case let .error(message):
            flushPendingChunk()
            statusMessage = message
            isRunning = false
            // Leave the queue intact on error — auto-dispatching into a failing
            // agent would loop; the user can retry or clear it.
        case let .exited(code):
            invalidateConfigOptionRequest()
            flushPendingChunk()
            isConnected = false
            isRunning = false
            supportsSteering = false
            injectingQueuedIDs.removeAll()
            pendingPermission = nil
            permissionQueue.removeAll()
            // Preserve queued user text for inspection/copying. The adapter is
            // gone so it cannot auto-dispatch, but silently deleting authored
            // follow-ups is worse than leaving them visible.
            let ending = code == 0 ? "The agent ended." : "The agent exited (code \(code))."
            statusMessage = queued.isEmpty
                ? ending
                : "\(ending) \(queued.count) queued follow-up\(queued.count == 1 ? " is" : "s are") ready to resume."
        }
    }

    /// Dispatch the next queued follow-up after a turn ends.
    ///
    /// Held while any injection is still in flight. Otherwise a turn that ends
    /// inside a `_session/steering` round trip would dispatch the very message
    /// the adapter is about to inject, and the user would say it twice.
    /// `applySteerOutcome` flushes again once the answer is in, so a refused
    /// injection is sent as its own turn immediately afterwards.
    private func flushQueue() {
        guard !isRunning, isConnected, injectingQueuedIDs.isEmpty, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        dispatch(next.text)
    }

    /// Streaming chunks accumulate into the current agent message/thought so the
    /// transcript grows smoothly rather than one row per chunk.
    private func accumulate(_ item: AcpTurnItem) {
        switch item {
        case let .message(_, text):
            bufferChunk(text, isThought: false)
        case let .thought(_, text):
            bufferChunk(text, isThought: true)
        case let .userMessage(adapterID, text):
            flushPendingChunk()
            appendUserChunk(adapterID: adapterID, text: text)
        case let .toolCall(call):
            // Anything that is not more of the current text has to wait for
            // that text to land, or a tool card jumps ahead of the sentence
            // that introduced it.
            flushPendingChunk()
            rows.append(.tool(call))
            publishFileActivity(for: call)
        case let .plan(entries):
            flushPendingChunk()
            let planID = "\(turnCounter)"
            if let index = rows.lastIndex(where: {
                if case let .plan(id, _) = $0 { return id == planID }
                return false
            }) {
                rows[index] = .plan(id: planID, entries: entries)
            } else {
                rows.append(.plan(id: planID, entries: entries))
            }
        }
    }

    private func publishFileActivity(for call: AcpToolCall) {
        for path in call.declaredFilePaths {
            let key = "\(call.id)\u{0}\(path)"
            guard !reportedFileActivityKeys.contains(key) else { continue }
            let accepted = onFileActivity?(AcpFileActivity(
                toolCallID: call.id,
                kind: call.kind,
                path: path
            )) ?? false
            guard accepted else { continue }
            reportedFileActivityKeys.insert(key)
            reportedFileActivityOrder.append(key)
        }
        let overflow = reportedFileActivityOrder.count - Self.maximumReportedFileActivityKeys
        guard overflow > 0 else { return }
        for key in reportedFileActivityOrder.prefix(overflow) {
            reportedFileActivityKeys.remove(key)
        }
        reportedFileActivityOrder.removeFirst(overflow)
    }

    /// Fold one adapter-reported `user_message_chunk` into the transcript.
    ///
    /// A prompt made of several content blocks replays as several chunks that
    /// share one `messageId` — Claude turns a file attachment into a link block
    /// plus a trailing `<context>` block, so the file's whole text arrives as
    /// extra chunks of the same message. The message is therefore decided ONCE,
    /// on its first chunk (whose text is exactly the text this client shows for
    /// its own sends), and every later chunk of that message follows that
    /// decision: extending the row it opened, or staying suppressed with it.
    /// Reconciling each chunk separately would leak a context dump into the
    /// transcript as its own user row.
    private func appendUserChunk(adapterID: String?, text: String) {
        if let adapterID, streamingUserMessage?.adapterID == adapterID {
            guard let rowID = streamingUserMessage?.rowID,
                  let index = rows.lastIndex(where: { $0.id == "user-\(rowID)" }),
                  case let .user(id, existing, _) = rows[index] else { return }
            rows[index] = .user(id: id, text: existing + text, failed: false)
            return
        }
        switch userMessageLedger.reconcile(text: text, adapterMessageID: adapterID) {
        case .drop:
            streamingUserMessage = adapterID.map { ($0, nil) }
        case let .append(id):
            rows.append(.user(id: id, text: text, failed: false))
            streamingUserMessage = adapterID.map { ($0, id) }
        }
    }

    /// Hold streaming text briefly instead of republishing on every chunk.
    ///
    /// Each chunk used to rewrite the last row and republish the whole `rows`
    /// array, so SwiftUI re-diffed the entire transcript per chunk while the
    /// message string was re-concatenated each time — quadratic in the length
    /// of the message, at streaming cadence. That is why text arrived in
    /// lurches. Buffering for one interval turns a burst of chunks into one
    /// update; nothing waits longer than the interval, so it still reads as
    /// live typing.
    ///
    /// Correctness rests on one rule: **buffered text lands before anything
    /// else touches `rows`.** `accumulate` is the only place streaming items
    /// arrive, so every non-text case there flushes first, and so do turn end
    /// and cancellation.
    private func bufferChunk(_ text: String, isThought: Bool) {
        // A thought/message switch opens a different row: publish the old one
        // before collecting the new.
        if let pending = pendingChunk, pending.isThought != isThought {
            flushPendingChunk()
        }
        // A chunk that *starts* a row is published immediately. Only text added
        // to a row that already exists is held back.
        //
        // Buffering the first chunk delayed the row itself, so for one interval
        // the transcript was missing a segment rather than missing its tail —
        // caught by `testNonContiguousSegmentsWithinOneTurnHaveUniqueRowIDs`,
        // which reads `rows` straight after a tool call and a following
        // message. Structure is what everything else keys off; only the text is
        // safe to coalesce.
        if pendingChunk == nil, wouldStartNewRow(isThought: isThought) {
            appendChunk(text, isThought: isThought)
            return
        }
        pendingChunk = ((pendingChunk?.text ?? "") + text, isThought)
        scheduleChunkFlush()
    }

    /// Whether the next chunk of this kind opens a row rather than extending
    /// the trailing one. Mirrors `appendChunk`'s own branch.
    private func wouldStartNewRow(isThought: Bool) -> Bool {
        guard let last = rows.last else { return true }
        if !isThought, case .message = last { return false }
        if isThought, case .thought = last { return false }
        return true
    }

    private func scheduleChunkFlush() {
        guard chunkFlushTask == nil else { return }
        chunkFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.chunkFlushInterval)
            guard let self else { return }
            self.chunkFlushTask = nil
            self.flushPendingChunk()
        }
    }

    /// Publish whatever has been collected. Safe to call at any time.
    func flushPendingChunk() {
        guard let pending = pendingChunk else { return }
        pendingChunk = nil
        appendChunk(pending.text, isThought: pending.isThought)
    }

    private func appendChunk(_ text: String, isThought: Bool) {
        if let last = rows.last {
            if !isThought, case let .message(id, existing) = last {
                rows[rows.count - 1] = .message(id: id, text: existing + text)
                return
            }
            if isThought, case let .thought(id, existing) = last {
                rows[rows.count - 1] = .thought(id: id, text: existing + text)
                return
            }
        }
        segmentCounter += 1
        let rowID = "\(turnCounter)-segment-\(segmentCounter)"
        rows.append(isThought ? .thought(id: rowID, text: text) : .message(id: rowID, text: text))
    }
}

/// Bounded ImageIO thumbnailing for image attachments whose encoded source is
/// too large for ACP's 5 MB image block. ImageIO subsamples while decoding, so
/// a high-resolution source never needs a full-size bitmap; the output is an
/// opaque sRGB JPEG whose dimensions and encoded bytes both stay bounded.
enum AcpImageDownscaler {
    struct Output: Equatable, Sendable {
        let data: Data
        let mimeType: String
        let pixelWidth: Int
        let pixelHeight: Int
    }

    static let maximumSourceBytes = 128 * 1_024 * 1_024
    /// 2K is ample prompt context while keeping each decode and flatten buffer
    /// near 16 MiB instead of materializing a camera-sized bitmap.
    static let maximumDimension = 2_048
    static let minimumDimension = 512
    private static let jpegQualities: [Double] = [0.84, 0.70, 0.56, 0.42]

    static func downscale(data: Data, maximumBytes: Int) -> Output? {
        guard data.count <= maximumSourceBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false,
              ] as CFDictionary) else { return nil }
        return downscale(source: source, maximumBytes: maximumBytes)
    }

    static func downscale(fileURL: URL, maximumBytes: Int) -> Output? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { return nil }
        return downscale(source: source, maximumBytes: maximumBytes)
    }

    private static func downscale(
        source: CGImageSource,
        maximumBytes: Int
    ) -> Output? {
        guard maximumBytes > 0, CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        guard let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else { return nil }

        var target = max(minimumDimension, min(max(width, height), maximumDimension))
        while target >= minimumDimension {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: target,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ), let flattened = flattenedJPEGSource(thumbnail) else { return nil }

            for quality in jpegQualities {
                guard let encoded = encodeJPEG(flattened, quality: quality) else { continue }
                if encoded.count <= maximumBytes {
                    return Output(
                        data: encoded,
                        mimeType: "image/jpeg",
                        pixelWidth: flattened.width,
                        pixelHeight: flattened.height
                    )
                }
            }

            guard target > minimumDimension else { break }
            target = max(minimumDimension, target * 3 / 4)
        }
        return nil
    }

    /// JPEG has no alpha channel. Composite transparent sources over white so
    /// screenshots and diagrams remain readable instead of acquiring black
    /// boxes where their transparent canvas used to be.
    private static func flattenedJPEGSource(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// Pure classification of a dropped/opened file into an `AcpAttachment`,
/// applying the image (≤ 5 MB after bounded downscaling) and UTF-8 text
/// (≤ 256 KB) size limits. No actor isolation, so it can run off the main
/// thread and be unit-tested directly.
enum AcpAttachmentClassifier {
    /// Images ride as base64 pixels; cap the encoded payload at 5 MB.
    static let maxImageBytes = 5 * 1024 * 1024
    /// Text files ride inline as an embedded resource block; cap at 256 KB.
    static let maxTextFileBytes = 256 * 1024
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif",
    ]

    enum Outcome: Equatable {
        case accepted(AcpAttachment)
        case rejected(reason: String)
    }

    static func classify(fileURL: URL) -> Outcome {
        let name = fileURL.lastPathComponent
        let ext = fileURL.pathExtension.lowercased()
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .rejected(reason: "\(name): not a readable file.")
        }
        // Pre-check the on-disk size so an oversized file is rejected without
        // being fully loaded into memory.
        let declaredSize = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int

        if imageExtensions.contains(ext) {
            if let declaredSize, declaredSize > AcpImageDownscaler.maximumSourceBytes {
                return .rejected(reason: oversize(name, kind: "images", limit: maxImageBytes))
            }
            if let declaredSize, declaredSize > maxImageBytes {
                guard let scaled = AcpImageDownscaler.downscale(
                    fileURL: fileURL,
                    maximumBytes: maxImageBytes
                ) else {
                    return .rejected(reason: "\(name): could not be downscaled safely below 5 MB.")
                }
                return .accepted(.image(
                    data: scaled.data,
                    mimeType: scaled.mimeType,
                    name: name
                ))
            }
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                return .rejected(reason: "\(name): could not be read.")
            }
            if data.count > AcpImageDownscaler.maximumSourceBytes {
                return .rejected(reason: oversize(name, kind: "images", limit: maxImageBytes))
            }
            if data.count > maxImageBytes {
                guard let scaled = AcpImageDownscaler.downscale(
                    data: data,
                    maximumBytes: maxImageBytes
                ) else {
                    return .rejected(reason: "\(name): could not be downscaled safely below 5 MB.")
                }
                return .accepted(.image(
                    data: scaled.data,
                    mimeType: scaled.mimeType,
                    name: name
                ))
            }
            return .accepted(.image(data: data, mimeType: mimeType(forExtension: ext), name: name))
        }

        // Non-image: accept only UTF-8 text within the text-file limit.
        if let declaredSize, declaredSize > maxTextFileBytes {
            return .rejected(reason: oversize(name, kind: "text files", limit: maxTextFileBytes))
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return .rejected(reason: "\(name): could not be read.")
        }
        guard data.count <= maxTextFileBytes else {
            return .rejected(reason: oversize(name, kind: "text files", limit: maxTextFileBytes))
        }
        guard let contents = String(data: data, encoding: .utf8) else {
            return .rejected(reason: "\(name): only UTF-8 text and image files can be attached.")
        }
        return .accepted(.textFile(path: fileURL.path, contents: contents, name: name))
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic", "heif": "image/heic"
        case "bmp": "image/bmp"
        case "tiff", "tif": "image/tiff"
        default: "application/octet-stream"
        }
    }

    private static func oversize(_ name: String, kind: String, limit: Int) -> String {
        let cap = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
        return "\(name) is too large — \(kind) must be ≤ \(cap)."
    }
}
