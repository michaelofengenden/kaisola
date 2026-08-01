import Foundation
import ImageIO
import KaisolaCore
import SwiftUI
import UniformTypeIdentifiers

/// One rendered row in the chat transcript.
enum AcpTranscriptRow: Codable, Identifiable, Equatable {
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

/// Drives one ACP agent conversation and accumulates its streaming turn into a
/// transcript the chat view renders. Owns the AcpClient; runs on the main actor
/// so published transcript mutations are UI-safe.
@MainActor
final class AcpConversation: ObservableObject {
    @Published private(set) var rows: [AcpTranscriptRow] = [] {
        didSet {
            contentVersion &+= 1
            onTranscriptChanged?(rows)
        }
    }
    /// Advances for both appended rows and in-place streaming updates. Views
    /// must follow this rather than `rows.count`: an agent can stream thousands
    /// of chunks into one existing Markdown row without changing the count.
    @Published private(set) var contentVersion: UInt64 = 0
    @Published private(set) var isRunning = false
    @Published private(set) var isConnected = false
    @Published private(set) var isReconnecting = false
    @Published private(set) var usage: AcpUsage?
    @Published private(set) var models: [AcpSessionInfo.Model] = []
    @Published private(set) var currentModelID: String?
    @Published private(set) var modes: [AcpSessionInfo.Mode] = []
    @Published private(set) var currentModeID: String?
    @Published private(set) var configOptions: [AcpConfigOption] = []
    @Published private(set) var commands: [AcpCommand] = []
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
    @Published private(set) var pendingAttachments: [PendingAttachment] = []
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
    /// The chat view renders only the last `visibleLimit` rows for performance;
    /// full history stays in `rows`. Grown by `expandEarlier()` ("Show earlier
    /// messages"); reset to the default when a new turn starts unless the user
    /// expanded during that turn. Settable so tests and the view can drive it.
    @Published var visibleLimit: Int = AcpConversation.defaultVisibleLimit

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
    var onTranscriptChanged: (([AcpTranscriptRow]) -> Void)?
    /// Live ACP-declared locations/diff paths for explicit follow mode. This is
    /// never derived from transcript prose. Return true only after the owner
    /// resolves and accepts the target; a not-yet-created file can then retry
    /// on a later tool update.
    var onFileActivity: ((AcpFileActivity) -> Bool)?
    var onProviderSessionID: ((String) -> Void)?
    var onDraftChanged: ((String) -> Void)?
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
    private let environment: [String: String]
    private let cwd: String
    private let mcpServers: [JSONValue]
    private let ruleStore: PermissionRuleStore
    private let sensitiveGlobs: [String]
    private let resumeSessionID: String?
    private var restoredDraft: String?
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
    /// Set when the user expands earlier history during the current turn, so the
    /// next turn keeps the widened window instead of snapping back to the tail.

    init(
        title: String,
        command: String,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cwd: String,
        mcpServers: [JSONValue] = [],
        client: AcpClient? = nil,
        clientFactory: (@MainActor () -> AcpClient)? = nil,
        ruleStore: PermissionRuleStore = PermissionRuleStore(),
        sensitiveGlobs: [String] = AcpPermissionRules.defaultSensitiveGlobs,
        draftKey: String? = nil,
        resumeSessionID: String? = nil,
        initialRows: [AcpTranscriptRow] = [],
        initialDraft: String? = nil,
        initialUsage: AcpUsage? = nil,
        initialQueuedPrompts: [String] = []
    ) {
        self.title = title
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
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
        self.restoredDraft = initialDraft
        self.usage = initialUsage
        self.queued = initialQueuedPrompts.enumerated().map { index, text in
            QueuedMessage(id: "q\(index + 1)", text: text)
        }
        self.queueCounter = initialQueuedPrompts.count
        self.turnCounter = initialRows.reduce(into: 0) { count, row in
            if case .user = row { count += 1 }
        }
        self.segmentCounter = initialRows.count
    }

    func start(resumeQueuedPrompts: Bool = false) async {
        guard !hasStarted else { return }
        hasStarted = true
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
            let info = try await client.start(
                command: command,
                arguments: arguments,
                environment: environment,
                cwd: cwd,
                mcpServers: mcpServers,
                resumeSessionID: providerSessionID ?? resumeSessionID
            )
            providerSessionID = info.sessionID
            onProviderSessionID?(info.sessionID)
            models = info.models
            currentModelID = info.currentModelID
            modes = info.modes
            currentModeID = info.currentModeID
            configOptions = info.configOptions
            isConnected = true
            statusMessage = nil
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

    /// Drop a still-pending queued follow-up before it dispatches.
    func removeQueued(_ id: String) {
        queued.removeAll { $0.id == id }
    }

    /// Resume a restored/paused FIFO. Dispatch removes exactly one item; the
    /// normal turn-end path advances the remainder one at a time.
    func resumeQueuedFollowUps() {
        flushQueue()
    }

    /// Steer: promote a queued follow-up to the front and interrupt the current
    /// turn so it dispatches now (the cancel ends the turn, and the normal
    /// turn-end flush sends the promoted message). Idle → dispatches directly.
    func steerQueued(_ id: String) {
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return }
        let message = queued.remove(at: index)
        if isRunning {
            queued.insert(message, at: 0)
            pendingPermission = nil
            permissionQueue.removeAll()
            Task { await client.cancel() }
        } else {
            dispatch(message.text)
        }
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
        let icon: String
        let size: Int
        switch attachment {
        case let .image(data, _, _): icon = "photo"; size = data.count
        case let .textFile(_, contents, _): icon = "doc.text"; size = contents.utf8.count
        }
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

    /// Set an adapter config option (effort level etc.); the client re-emits the
    /// adapter's normalized option set, which `consume` applies.
    func selectConfigOption(_ id: String, value: String) {
        if let index = configOptions.firstIndex(where: { $0.id == id }) {
            configOptions[index].currentValue = value   // optimistic
        }
        Task { await client.setConfigOption(id: id, value: value) }
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
        draftPersistenceTask?.cancel()
        draftPersistenceTask = nil
        let finalDraft = pendingDraftPersistence
        pendingDraftPersistence = nil
        await client.stop()
        isConnected = false
        isRunning = false
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

    /// The tail of `rows` the chat view actually renders — the last
    /// `visibleLimit` rows. Full history is always kept in `rows`; only the
    /// rendered window is bounded so long chats stay smooth.
    var visibleRows: [AcpTranscriptRow] {
        rows.count > visibleLimit ? Array(rows.suffix(visibleLimit)) : rows
    }

    /// How many earlier rows sit above the rendered window.
    var hiddenEarlierCount: Int {
        max(0, rows.count - visibleLimit)
    }

    /// Reveal `expandStep` (200) more earlier rows when the view reaches the top.
    func expandEarlier() {
        visibleLimit = min(rows.count, visibleLimit + Self.expandStep)
    }

    // MARK: - Persistent draft

    private var draftDefaultsKey: String? {
        draftStorageKey.map { "chatDraft.\($0)" }
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

    // MARK: - Test hooks

    /// Test-only: replace the transcript wholesale so paging math can be
    /// exercised without driving a live turn. Not called by production code.
    func seedRowsForTesting(_ newRows: [AcpTranscriptRow]) {
        rows = newRows
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

            Inspect `PULL_REQUEST_FEATURES.md:211` for the exact acceptance contract.
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
            isRunning = false
            onAttention?(.turnCompleted, "Finished a turn")
            flushQueue()
        case let .error(message):
            statusMessage = message
            isRunning = false
            // Leave the queue intact on error — auto-dispatching into a failing
            // agent would loop; the user can retry or clear it.
        case let .exited(code):
            isConnected = false
            isRunning = false
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
    private func flushQueue() {
        guard !isRunning, isConnected, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        dispatch(next.text)
    }

    /// Streaming chunks accumulate into the current agent message/thought so the
    /// transcript grows smoothly rather than one row per chunk.
    private func accumulate(_ item: AcpTurnItem) {
        switch item {
        case let .message(_, text):
            appendChunk(text, isThought: false)
        case let .thought(_, text):
            appendChunk(text, isThought: true)
        case let .toolCall(call):
            rows.append(.tool(call))
            publishFileActivity(for: call)
        case let .plan(entries):
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
