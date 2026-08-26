import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One spoken contract for the symbol-only checkpoint menu and its destructive
/// choices. Keep the consequence in the choice hint even though a confirmation
/// follows: VoiceOver users need to understand the action before selecting it.
enum CheckpointMenuAccessibility {
    static let label = "Restore checkpoint"
    static let hint = "Choose a snapshot taken before a turn. "
        + "Restoring replaces current working tree files after confirmation."
    static let choiceHint = "Replaces current working tree files with this snapshot after confirmation."
    static let identifier = "acp.checkpoints.restore"

    static func value(checkpointCount: Int) -> String {
        "\(checkpointCount) checkpoint\(checkpointCount == 1 ? "" : "s") available"
    }

    static func choiceLabel(turn: Int, time: String) -> String {
        "Restore checkpoint before turn \(turn) at \(time)"
    }
}

/// One deterministic spoken contract for staged attachments. The chip owns
/// the filename and size while its destructive child names the exact file it
/// removes; focus routing never depends on a row index after the mutation.
enum AcpAttachmentAccessibility {
    enum FocusDestination: Equatable {
        case removalButton(id: String)
        case attachmentControl
    }

    static func chipLabel(name: String) -> String {
        "Attachment \(name)"
    }

    static func chipValue(byteSize: Int) -> String {
        "Size \(ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file))"
    }

    static func removalLabel(name: String) -> String {
        "Remove attachment \(name)"
    }

    static func removalAnnouncement(name: String) -> String {
        "Removed attachment \(name)"
    }

    static func focusDestination(removing id: String, orderedIDs: [String]) -> FocusDestination {
        guard let index = orderedIDs.firstIndex(of: id),
              orderedIDs.indices.contains(index + 1) else {
            return .attachmentControl
        }
        return .removalButton(id: orderedIDs[index + 1])
    }
}

/// The ACP conversation surface: streaming messages, thinking blocks,
/// tool-call cards, a plan, a live permission prompt, model picker, usage, and
/// a composer. Mirrors the Electron Assistant transcript.
struct AcpChatView: View {
    /// Controls how much session chrome the chat owns. A unified session card
    /// already renders identity and activity, so its embedded chat keeps only
    /// the agent controls above the transcript.
    enum Presentation: Sendable, Equatable {
        case standard
        case embedded
    }

    @ObservedObject var conversation: AcpConversation
    @ObservedObject private var accountAccess: ChatAccountAccess
    private let presentation: Presentation
    @State private var draft = ""
    /// Highlights the composer while an OS file drag hovers it.
    @State private var isDropTargeted = false
    @State private var transcriptIsReady = false
    @State private var loadingEarlierRows = false
    @State private var transcriptIsAtBottom = true
    /// Whether streaming output keeps the transcript pinned to its tail.
    /// This is the user's *intent*, set only by their own scrolling (or the
    /// jump pill, or sending a message) — never by what streaming pushed
    /// offscreen. `transcriptIsAtBottom` remains the sentinel's report of
    /// what is visible; conflating the two was why follow silently died the
    /// moment output outran the scroll pin.
    @State private var transcriptFollowsTail = true
    @State private var hasUnseenTranscriptUpdates = false
    /// The status row's subagent clause, recomputed once per content version
    /// in `onChange` rather than in the body: a streaming turn re-evaluates
    /// the transcript body far more often than its content actually changes,
    /// and the derivation walks rows.
    @State private var subagentStatusDetail: String?
    /// Coalesces tail pins. One scroll-to-bottom per streamed chunk was the
    /// old at-bottom behavior too, but the sentinel bug used to kill follow
    /// within moments — accidental overload protection. Intent-based follow
    /// survives the whole turn, so on a large transcript an every-chunk pin
    /// became a layout storm that pegged a core and starved painting.
    @State private var transcriptTailPinScheduled = false
    /// The folded transcript (markers instead of tool-call runs), recomputed
    /// once per content version alongside the other derived state — never in
    /// the body.
    @State private var displayItems: [AcpTranscriptDisplayItem] = []
    /// Message rows that are a turn's final answer and so carry the response
    /// chrome; interim narration renders as plain prose.
    @State private var finalResponseIDs: Set<String> = []
    /// Work markers the user has opened. Keyed by the run's stable id, so an
    /// open run stays open while the turn streams; reset by remount, so a
    /// revisited chat starts quiet again.
    @State private var expandedRunIDs: Set<String> = []
    /// Tool-call ids of the turn in flight, so a chip's "in background" claim
    /// dies with its own turn instead of resurrecting on any later one.
    @State private var currentTurnToolIDs: Set<String> = []

    /// One scan per body pass: which mounted item carries the search match.
    private var highlightedDisplayItemID: String? {
        guard let current = transcriptSearch.currentRowID else { return nil }
        if displayItems.contains(where: { $0.id == current }) { return current }
        return AcpTranscriptDisplay.runID(containing: current, in: displayItems)
    }

    private func rowShowsResponseChrome(_ row: AcpTranscriptRow) -> Bool {
        if case let .message(id, _) = row {
            return finalResponseIDs.contains(id)
        }
        return true
    }

    private func refreshDisplayState() {
        let rows = conversation.visibleRows
        displayItems = AcpTranscriptDisplay.items(rows: rows, isRunning: conversation.isRunning)
        finalResponseIDs = AcpTranscriptDisplay.finalResponseMessageIDs(rows: rows)
        subagentStatusDetail = AcpSubagentSummary.derive(rows: rows)?.label
        var spawns: Set<String> = []
        for row in rows.reversed() {
            if case .user = row { break }
            if case let .tool(call) = row { spawns.insert(call.id) }
        }
        currentTurnToolIDs = spawns
    }
    @State private var transcriptConversationID: ObjectIdentifier?
    /// The one subagent being watched as a floating card, or nil. Watching a
    /// second replaces the first: two live feeds racing each other over the
    /// same corner answer no question a reader is actually asking.
    @State private var subagentWatchTarget: AcpSubagentWatchTarget?
    @StateObject private var transcriptViewportAnchor = AcpTranscriptViewportAnchor()
    @ObservedObject private var previewSettings = NativePreviewSettings.shared
    @State private var densityAnchorGeneration: UInt64 = 0
    @FocusState private var composerFocused: Bool
    @FocusState private var focusedAttachmentRemovalID: String?
    @AccessibilityFocusState private var accessibilityFocusedAttachmentRemovalID: String?
    @FocusState private var attachmentControlFocused: Bool
    @AccessibilityFocusState private var attachmentControlAccessibilityFocused: Bool
    private let focusRequestGeneration: UInt64?
    private let onKeyboardFocus: (() -> Void)?
    private let onSignIn: () -> Void
    private let onChooseAccount: () -> Void
    private let onPreserveTranscript: () -> Void

    private struct StartupTaskID: Hashable {
        let conversation: ObjectIdentifier
        let accountAllowsStart: Bool
    }

    init(
        conversation: AcpConversation,
        accountAccess: ChatAccountAccess,
        presentation: Presentation = .standard,
        focusRequestGeneration: UInt64? = nil,
        onKeyboardFocus: (() -> Void)? = nil,
        onSignIn: @escaping () -> Void = {},
        onChooseAccount: @escaping () -> Void = {},
        onPreserveTranscript: @escaping () -> Void = {}
    ) {
        _conversation = ObservedObject(wrappedValue: conversation)
        _accountAccess = ObservedObject(wrappedValue: accountAccess)
        self.presentation = presentation
        self.focusRequestGeneration = focusRequestGeneration
        self.onKeyboardFocus = onKeyboardFocus
        self.onSignIn = onSignIn
        self.onChooseAccount = onChooseAccount
        self.onPreserveTranscript = onPreserveTranscript
    }

    /// The chat has produced nothing yet, so the transcript's space belongs to
    /// the invitation instead. A restored chat arrives with its tail page
    /// already applied (`AppModel.appendChat(initialTranscript:)`), and a
    /// paged-out history leaves `hiddenEarlierCount` non-zero, so neither
    /// flashes "What should we build…" on the way in.
    private var showsEmptyState: Bool {
        conversation.rows.isEmpty && conversation.hiddenEarlierCount == 0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Embedded chats draw no header of their own (2026-08-26): the
            // containing pane's 32pt header is the one bar, and the session
            // controls live in its overflow menu. The second strip this used
            // to draw — zoom, checkpoints, usage fraction, export — was chrome
            // over chrome.
            if presentation == .standard {
                standardHeader
                Divider()
            }
            if conversation.transcriptRetentionStatus.isTruncated {
                transcriptRetentionNotice
                Divider()
            }
            if conversation.transcriptPersistenceHealth.needsAttention {
                transcriptPersistenceNotice
                Divider()
            }
            if showsEmptyState {
                emptyState
            } else {
                transcript
            }
            if let review = conversation.pendingPermissionReview {
                AcpPermissionBar(
                    review: review,
                    allowsRule: conversation.pendingPermissionAllowsRule,
                    pendingCount: conversation.pendingPermissionCount,
                    deny: { conversation.denyPermission() },
                    allowOnce: { conversation.allowPermissionOnce() },
                    createRule: { conversation.answerPermissionAlways() }
                )
            }
            composer
        }
        // The drop target is the whole chat, not just the composer.
        //
        // It used to be the composer alone — a ~90pt gutter at the very bottom
        // — so a screenshot dragged at the transcript, which is all of the
        // conversation and most of the pane, landed on nothing and silently did
        // nothing. A drag aimed anywhere in a chat is aimed at that chat, and
        // asking the user to find the one strip that accepts it is precision a
        // drag should never demand. `handleDrop` is unchanged, so
        // `AcpAttachmentClassifier` still decides what is attachable.
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted {
                // `paneRadius`, not `panelRadius`: the ring sits just inside
                // the pane's own clip, and an 18pt arc inset 6pt inside an
                // 11pt clip lost its corners to the clip — four different
                // dash fragments where the corners should be.
                RoundedRectangle(cornerRadius: KaisolaVisualSystem.paneRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // SwiftUI can reuse this view position when the selected chat changes.
        // Key the startup work to the object so a new session never flashes or
        // saves the preceding session's draft.
        .task(id: ObjectIdentifier(conversation)) {
            transcriptSearch = AcpTranscriptSearchState()
            draft = conversation.loadDraft()
        }
        .task(id: StartupTaskID(
            conversation: ObjectIdentifier(conversation),
            accountAllowsStart: accountAccess.allowsAdapterStart
        )) {
            guard accountAccess.allowsAdapterStart else { return }
            await conversation.start()
        }
        .onChange(of: draft) { _, newValue in
            conversation.saveDraft(newValue)
        }
        .onAppear { applyFocusRequest(focusRequestGeneration) }
        .onChange(of: focusRequestGeneration) { _, request in
            applyFocusRequest(request)
        }
        .onReceive(NotificationCenter.default.publisher(for: .kaisolaTranscriptFindCommand)) { notification in
            handleTranscriptFindCommand(notification)
        }
    }

    private var transcriptRetentionNotice: some View {
        let status = conversation.transcriptRetentionStatus
        let bytes = ByteCountFormatter.string(
            fromByteCount: status.truncatedByteCount,
            countStyle: .file
        )
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Earlier saved history was truncated at this chat's disk quota (\(status.truncatedRowCount.formatted()) rows, \(bytes)). User prompts, tool evidence, and the newest transcript were kept first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Saved chat history truncated")
        .accessibilityValue("\(status.truncatedRowCount) rows and \(bytes) removed after this chat reached its disk quota")
    }

    private var transcriptPersistenceNotice: some View {
        let health = conversation.transcriptPersistenceHealth
        let detail: String
        let canRetry: Bool
        switch health {
        case .healthy:
            detail = ""
            canRetry = false
        case let .retrying(attempt, maximumAttempts):
            detail = "Saving the latest transcript failed. Retry \(attempt) of \(maximumAttempts) is pending; keep this chat open."
            canRetry = false
        case let .failed(failure):
            detail = "\(failure.detail) \(failure.guidance)"
            canRetry = true
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if canRetry {
                Button("Retry") { conversation.retryTranscriptPersistence() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Button("Export Recovery Copy") { exportTranscriptRecoveryCopy() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("acp.transcriptPersistenceWarning")
        .accessibilityLabel("Transcript is not saved")
        .accessibilityValue(detail)
    }

    @MainActor
    private func exportTranscriptRecoveryCopy() {
        let panel = NSSavePanel()
        panel.title = "Export Chat Transcript Recovery Copy"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = AcpTranscriptRecoveryExport.suggestedFileName(
            for: conversation.title
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try AcpTranscriptRecoveryExport.data(
                title: conversation.title,
                startOrdinal: conversation.loadedRowStartOrdinal,
                rows: conversation.rows
            )
            try data.write(to: url, options: .atomic)
        } catch {
            ToastCenter.shared.show(
                "Could not export the transcript recovery copy: \(error.localizedDescription)",
                style: .error
            )
        }
    }

    private var standardHeader: some View {
        HStack(spacing: 10) {
            // Green-versus-grey is invisible to a red/green-blind user and to
            // VoiceOver alike, so the dot loses its fill when the adapter is
            // detached and says which state it is in.
            Group {
                if conversation.isConnected {
                    Circle().fill(Color.green)
                } else {
                    Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5)
                }
            }
            .frame(width: 7, height: 7)
            .accessibilityElement()
            .accessibilityLabel(conversation.isConnected ? "Connected" : "Not connected")
            .help(conversation.isConnected ? "Connected" : "Not connected")
            Text(conversation.title).font(.subheadline.weight(.medium))
            // No working spinner here: the transcript's thinking status row
            // is the running-turn signal, and a second indicator in the
            // header would say the same fact twice.
            Spacer()
            AcpChatOverflowMenu(conversation: conversation)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        // Parity with the embedded pane header: the standalone window's one
        // bar speaks the same white-led surface instead of inheriting
        // whatever sits behind it.
        .kaisolaBarSurface()
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            if transcriptSearch.isPresented {
                transcriptSearchBar
                Divider()
            }
            transcriptScrollView
        }
    }

    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    // Spacing zero: the rhythm lives in the pure pair table on
                    // `AcpTranscriptMetrics`, applied per row, so a turn
                    // boundary is a larger event than the next artifact.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if conversation.hiddenEarlierCount > 0 {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(loadingEarlierRows ? "Loading earlier messages…" : "Earlier messages")
                                    .font(.caption)
                                    .foregroundStyle(.kaisolaSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 6)
                            .padding(.bottom, AcpTranscriptMetrics.intraTurnSpacing)
                            .onAppear {
                                loadEarlierRows(using: proxy)
                            }
                        } else if transcriptIsReady, !conversation.rows.isEmpty {
                            Label("Beginning of session", systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.kaisolaSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 6)
                                .padding(.bottom, AcpTranscriptMetrics.intraTurnSpacing)
                                .accessibilityLabel("Beginning of session history")
                        }
                        if let status = conversation.statusMessage {
                            Label(status, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.kaisolaSecondary)
                                .padding(.bottom, AcpTranscriptMetrics.intraTurnSpacing)
                        }
                        // Display items, not raw rows: bursts of plain tool
                        // calls fold into one expandable marker line, the way
                        // the Codex app logs work, and only prose, thoughts,
                        // chips, and the live tail keep their own line.
                        ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                            transcriptDisplayItem(item, index: index)
                        }
                        if let status = conversation.liveThinkingStatus {
                            AcpThinkingStatusRow(
                                status: status,
                                subagentDetail: subagentStatusDetail,
                                startedAt: conversation.turnStartedAt
                            )
                                .id("acp-thinking-status")
                                .padding(.top, AcpTranscriptMetrics.spacing(
                                    before: displayItems.last?.rhythmKind,
                                    after: .assistant
                                ))
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("acp-transcript-bottom")
                            .onAppear {
                                transcriptIsAtBottom = true
                                hasUnseenTranscriptUpdates = false
                                // Reaching the bottom by any means — keyboard,
                                // scrollbar, momentum — re-engages follow.
                                transcriptFollowsTail = true
                            }
                            .onDisappear { transcriptIsAtBottom = false }
                    }
                    .padding(.horizontal, AcpTranscriptMetrics.horizontalPadding)
                    .padding(.vertical, AcpTranscriptMetrics.pagePadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        AcpTranscriptScrollIntentSensor { distance in
                            let follows = AcpTranscriptFollowPolicy.follows(
                                afterUserScrollDistance: distance
                            )
                            if follows != transcriptFollowsTail {
                                transcriptFollowsTail = follows
                            }
                            if follows { hasUnseenTranscriptUpdates = false }
                        }
                    }
                }
                // Content mounts already sitting at its end. Without an
                // anchor, SwiftUI laid the transcript out at offset zero and
                // the mount then chased the bottom across frames — which read
                // as the whole history scrolling past on every open. Scoped
                // to the initial offset where the OS allows: unscoped, the
                // anchor also governs size changes, which would drag a
                // deliberately scrolled-up reader back to the tail and glue a
                // short transcript to the composer.
                .modifier(TranscriptBottomAnchorModifier(followsTail: transcriptFollowsTail))
                .modifier(TranscriptTopEdgeModifier())

                // Keyed to intent, not visibility: while follow is engaged the
                // sentinel can flicker offscreen between pins during a fast
                // stream, and a pill that blinks through every burst reads as
                // "following is broken" — which it was.
                // The watched subagent's floating card, pinned to the
                // workspace's top-trailing corner over the stream it watches.
                if let watchTarget = subagentWatchTarget {
                    SubagentWatchCard(target: watchTarget) {
                        withAnimation(.spring(duration: 0.25)) { subagentWatchTarget = nil }
                    }
                    .padding(.top, 10)
                    .padding(.trailing, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if transcriptIsReady, !transcriptFollowsTail, !conversation.rows.isEmpty {
                    Button {
                        hasUnseenTranscriptUpdates = false
                        transcriptFollowsTail = true
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("acp-transcript-bottom", anchor: .bottom)
                        }
                    } label: {
                        Label(
                            hasUnseenTranscriptUpdates ? "New output" : "Jump to latest",
                            systemImage: "arrow.down"
                        )
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(12)
                    .help("Return to the latest agent output")
                    .accessibilityHint("Scrolls the transcript to the newest output")
                }
            }
            .onAppear {
                transcriptConversationID = ObjectIdentifier(conversation)
                // A chat you return to opens at its end, exactly like one you
                // just restored: collapse the render window a reader may have
                // expanded, so a remount never mounts thousands of rows.
                conversation.collapseToTail()
                expandedRunIDs.removeAll()
                subagentWatchTarget = nil
                transcriptSearch.refresh(rows: conversation.visibleRows)
                transcriptIsReady = false
                transcriptIsAtBottom = true
                transcriptFollowsTail = true
                hasUnseenTranscriptUpdates = false
                refreshDisplayState()
                DispatchQueue.main.async {
                    proxy.scrollTo("acp-transcript-bottom", anchor: .bottom)
                    transcriptIsReady = true
                }
            }
            .onChange(of: conversation.contentVersion, initial: true) { _, newVersion in
                transcriptSearch.refresh(rows: conversation.visibleRows)
                refreshDisplayState()
                guard transcriptIsReady,
                      conversation.lastHistoryInsertionContentVersion != newVersion else { return }
                if transcriptFollowsTail {
                    scheduleTailPin(using: proxy)
                } else {
                    hasUnseenTranscriptUpdates = true
                }
            }
            .onChange(of: conversation.localSendVersion) { _, _ in
                // Sending a message is asking to see the reply: it re-engages
                // follow even from deep in history.
                transcriptFollowsTail = true
                hasUnseenTranscriptUpdates = false
                DispatchQueue.main.async {
                    proxy.scrollTo("acp-transcript-bottom", anchor: .bottom)
                }
            }
            .onChange(of: conversation.isRunning) { _, _ in
                // The turn's end folds the live tail rows back into their
                // marker; the start splits them out.
                refreshDisplayState()
            }
            .onChange(of: searchNavigationRequest) { _, request in
                guard let request,
                      let rowID = transcriptSearch.move(request.direction) else { return }
                // A match hidden inside a collapsed work marker opens it
                // first, or the scroll would target an id that isn't mounted.
                if let runID = AcpTranscriptDisplay.runID(containing: rowID, in: displayItems) {
                    expandedRunIDs.insert(runID)
                    // The card mounts on the state change; scroll after it.
                    DispatchQueue.main.async {
                        TerminalTranscriptScrollPolicy.preserveUserVelocity {
                            proxy.scrollTo(rowID, anchor: .center)
                        }
                    }
                } else {
                    TerminalTranscriptScrollPolicy.preserveUserVelocity {
                        proxy.scrollTo(rowID, anchor: .center)
                    }
                }
            }
            .onChange(of: searchPageRequestGeneration) { _, _ in
                loadEarlierRows(using: proxy)
            }
            .onChange(of: previewSettings.toolCallDensity) { _, density in
                preserveReadingAnchorForToolCallDensity(density, using: proxy)
            }
        }
        .id(ObjectIdentifier(conversation))
        .dynamicTypeSize(previewSettings.agentChatTextSize.dynamicTypeSize)
    }

    /// One display item of the stream, with its viewport marker, search
    /// highlight, and rhythm spacing. Extracted from the transcript `ForEach`
    /// body: the inline version pushed that expression past the
    /// type-checker's budget.
    @ViewBuilder
    private func transcriptDisplayItem(_ item: AcpTranscriptDisplayItem, index: Int) -> some View {
        Group {
            switch item {
            case let .row(row):
                TranscriptRowView(
                    row: row,
                    workspaceURL: conversation.workspaceURL,
                    retry: { conversation.retryFailed($0) },
                    terminalSnapshot: { [weak conversation] id in await conversation?.terminalSnapshot(id) },
                    showsResponseChrome: rowShowsResponseChrome(row),
                    onWatchSubagent: toggleSubagentWatch,
                    conversationIsRunning: conversation.isRunning
                        && { if case let .tool(call) = row { return currentTurnToolIDs.contains(call.id) }; return true }()
                )
            case let .workRun(_, calls):
                WorkRunMarkerRow(
                    calls: calls,
                    expanded: expandedRunIDs.contains(item.id),
                    workspaceURL: conversation.workspaceURL,
                    terminalSnapshot: { [weak conversation] id in await conversation?.terminalSnapshot(id) },
                    toggle: {
                        if expandedRunIDs.contains(item.id) {
                            expandedRunIDs.remove(item.id)
                        } else {
                            expandedRunIDs.insert(item.id)
                        }
                    }
                )
            case let .harnessNotice(_, summary, text):
                HarnessNoticeRow(summary: summary, fullText: text)
            }
        }
        .id(item.id)
        .background {
            AcpTranscriptViewportMarker(
                rowID: item.id,
                anchor: transcriptViewportAnchor
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            if let highlighted = highlightedDisplayItemID,
               highlighted == item.id {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.12))
                    .accessibilityHidden(true)
            }
        }
        // After the backgrounds, so the viewport marker and search highlight
        // hug the row rather than annexing the turn gap above it.
        .padding(.top, AcpTranscriptMetrics.spacing(
            before: index == 0 ? nil : displayItems[index - 1].rhythmKind,
            after: item.rhythmKind
        ))
    }

    /// Watch toggles: the same chip closes its own card, a different chip
    /// replaces it.
    private func toggleSubagentWatch(_ target: AcpSubagentWatchTarget) {
        withAnimation(.spring(duration: 0.3)) {
            subagentWatchTarget = subagentWatchTarget?.id == target.id ? nil : target
        }
    }

    /// At most one pending pin at a time, fired a beat later, so a burst of
    /// streamed chunks collapses into a single scroll-and-layout pass. Intent
    /// is re-checked at fire time: a user scroll during the wait wins. No
    /// animation — an ease re-targeted at every burst lags the tail it is
    /// chasing, and the content's own growth already reads as motion.
    private func scheduleTailPin(using proxy: ScrollViewProxy) {
        guard !transcriptTailPinScheduled else { return }
        transcriptTailPinScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) {
            transcriptTailPinScheduled = false
            guard transcriptFollowsTail else { return }
            proxy.scrollTo("acp-transcript-bottom", anchor: .bottom)
        }
    }

    @State private var transcriptSearch = AcpTranscriptSearchState()
    @State private var searchNavigationGeneration: UInt64 = 0
    @State private var searchNavigationRequest: AcpTranscriptSearchNavigationRequest?
    @State private var searchPageRequestGeneration: UInt64 = 0
    @FocusState private var transcriptSearchFocused: Bool

    private var transcriptSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(
                "Find in conversation",
                text: Binding(
                    get: { transcriptSearch.query },
                    set: { transcriptSearch.updateQuery($0, rows: conversation.visibleRows) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .focused($transcriptSearchFocused)
            .onSubmit { requestTranscriptSearchNavigation(.next) }
            .accessibilityIdentifier("acp.transcript.search.field")
            .accessibilityHint("Searches the loaded transcript without moving your reading position")

            Text(transcriptSearch.statusText(hasHiddenEarlierRows: conversation.hiddenEarlierCount > 0))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.kaisolaSecondary)
                .fixedSize()
                .accessibilityIdentifier("acp.transcript.search.status")

            if conversation.hiddenEarlierCount > 0, !transcriptSearch.query.isEmpty {
                Button {
                    searchPageRequestGeneration &+= 1
                } label: {
                    Label("Search earlier", systemImage: "arrow.up.to.line")
                        .labelStyle(.iconOnly)
                }
                .disabled(loadingEarlierRows)
                .help("Load an earlier transcript page and include it in search")
                .accessibilityLabel("Search earlier messages")
                .accessibilityHint("Loads older messages without moving the current reading position")
                .accessibilityIdentifier("acp.transcript.search.earlier")
            }

            Button { requestTranscriptSearchNavigation(.previous) } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(transcriptSearch.matches.isEmpty)
            .help("Previous match")
            .accessibilityLabel("Previous transcript match")
            .accessibilityIdentifier("acp.transcript.search.previous")

            Button { requestTranscriptSearchNavigation(.next) } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(transcriptSearch.matches.isEmpty)
            .help("Next match")
            .accessibilityLabel("Next transcript match")
            .accessibilityIdentifier("acp.transcript.search.next")

            Button { dismissTranscriptSearch() } label: {
                Image(systemName: "xmark")
            }
            .help("Close Find")
            .accessibilityLabel("Close transcript search")
            .accessibilityIdentifier("acp.transcript.search.close")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .kaisolaBarSurface()
        .onExitCommand { dismissTranscriptSearch() }
        .onChange(of: transcriptSearchFocused) { _, isFocused in
            if isFocused { onKeyboardFocus?() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in ACP transcript")
        .accessibilityIdentifier("acp.transcript.search")
    }

    private func handleTranscriptFindCommand(_ notification: Notification) {
        guard let source = notification.object as? AcpConversation,
              source === conversation,
              let rawValue = notification.userInfo?[AcpTranscriptFindCommand.notificationActionKey] as? Int,
              let command = AcpTranscriptFindCommand(rawValue: rawValue) else { return }
        switch command {
        case .show, .useSelection:
            presentTranscriptSearch()
        case .next:
            requestTranscriptSearchNavigation(.next)
        case .previous:
            requestTranscriptSearchNavigation(.previous)
        }
    }

    private func presentTranscriptSearch() {
        transcriptSearch.present()
        transcriptSearch.refresh(rows: conversation.visibleRows)
        composerFocused = false
        DispatchQueue.main.async { transcriptSearchFocused = true }
    }

    private func dismissTranscriptSearch() {
        transcriptSearch.dismiss()
        transcriptSearchFocused = false
    }

    private func requestTranscriptSearchNavigation(_ direction: AcpTranscriptSearchDirection) {
        if !transcriptSearch.isPresented { presentTranscriptSearch() }
        searchNavigationGeneration &+= 1
        searchNavigationRequest = AcpTranscriptSearchNavigationRequest(
            generation: searchNavigationGeneration,
            direction: direction
        )
    }

    private func loadEarlierRows(using proxy: ScrollViewProxy) {
        guard transcriptIsReady,
              transcriptConversationID == ObjectIdentifier(conversation),
              !loadingEarlierRows,
              conversation.hiddenEarlierCount > 0 else { return }
        loadingEarlierRows = true
        Task { @MainActor in
            // `searchPageRequestGeneration` changes during a SwiftUI update
            // transaction. Measuring AppKit from that transaction can see the
            // old LazyVStack mount set even though the corresponding rows are
            // already visible through accessibility. Cross a main-run-loop
            // boundary before capture, and retry once because SwiftUI may use
            // the first pass to mount a newly exposed lazy row.
            await nextTranscriptLayoutPass()
            var mountedAnchor = transcriptViewportAnchor.capture()
            if mountedAnchor == nil {
                await nextTranscriptLayoutPass()
                mountedAnchor = transcriptViewportAnchor.capture()
            }
            let fallbackAnchor = displayItems.first?.id
            guard mountedAnchor != nil || fallbackAnchor != nil else {
                loadingEarlierRows = false
                return
            }
            await conversation.expandEarlier()
            guard transcriptConversationID == ObjectIdentifier(conversation) else {
                loadingEarlierRows = false
                return
            }
            transcriptSearch.refresh(rows: conversation.visibleRows)
            // Let SwiftUI lay out the prepended page before measuring its real
            // AppKit document geometry. The mounted marker preserves the
            // reader's exact intra-row offset; the data-window first row is
            // retained only as a safe pre-mount fallback.
            await nextTranscriptLayoutPass()
            if let mountedAnchor {
                let restoration = await restoreMountedTranscriptAnchor(
                    mountedAnchor,
                    using: proxy
                )
                emitVisualTranscriptAnchorReceipt(
                    restoration,
                    failureReason: "restore-no-mounted-anchor"
                )
            } else if let fallbackAnchor {
                TerminalTranscriptScrollPolicy.preserveUserVelocity {
                    proxy.scrollTo(fallbackAnchor, anchor: .top)
                }
                emitVisualTranscriptAnchorReceipt(
                    nil,
                    failureReason: "capture-no-mounted-anchor"
                )
            }
            loadingEarlierRows = false
        }
    }

    @MainActor
    private func nextTranscriptLayoutPass() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// LazyVStack is allowed to unmount the captured row while it inserts a
    /// large earlier page. Bring that exact identity back into the mounted
    /// window if necessary, then require two consecutive run-loop passes with
    /// a real AppKit restoration. The second pass catches a delayed SwiftUI
    /// content-size correction instead of issuing a premature success receipt.
    private func restoreMountedTranscriptAnchor(
        _ snapshot: AcpTranscriptViewportAnchor.Snapshot,
        using proxy: ScrollViewProxy
    ) async -> AcpTranscriptViewportAnchor.Restoration? {
        var didRequestMount = false
        var consecutiveRestorations = 0

        for _ in 0..<6 {
            if let restoration = transcriptViewportAnchor.restore(snapshot) {
                consecutiveRestorations += 1
                if consecutiveRestorations == 2 { return restoration }
            } else {
                consecutiveRestorations = 0
                if !didRequestMount {
                    didRequestMount = true
                    TerminalTranscriptScrollPolicy.preserveUserVelocity {
                        proxy.scrollTo(snapshot.rowID, anchor: .top)
                    }
                }
            }
            await nextTranscriptLayoutPass()
        }
        return nil
    }

    /// Compact/Balanced/Detailed can reflow every mounted tool card at once.
    /// Capture the actual top reading row before SwiftUI commits that height
    /// change, then restore its exact intra-row offset after the new density is
    /// laid out. A generation guard makes rapid menu changes last-write-wins.
    private func preserveReadingAnchorForToolCallDensity(
        _ density: ToolCallDensity,
        using proxy: ScrollViewProxy
    ) {
        guard transcriptIsReady,
              transcriptConversationID == ObjectIdentifier(conversation),
              let snapshot = transcriptViewportAnchor.capture() else { return }
        densityAnchorGeneration &+= 1
        let generation = densityAnchorGeneration
        Task { @MainActor in
            await nextTranscriptLayoutPass()
            guard generation == densityAnchorGeneration,
                  transcriptConversationID == ObjectIdentifier(conversation) else { return }
            let restoration = await restoreMountedTranscriptAnchor(snapshot, using: proxy)
            emitVisualTranscriptDensityAnchorReceipt(restoration, density: density)
        }
    }

    private func emitVisualTranscriptDensityAnchorReceipt(
        _ restoration: AcpTranscriptViewportAnchor.Restoration?,
        density: ToolCallDensity
    ) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
              environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "mixed-density" else { return }
        let line: String
        if let restoration {
            line = "KAISOLA_NATIVE_TRANSCRIPT_DENSITY_ANCHOR=PASS "
                + "density=\(density.rawValue) "
                + "row=\(restoration.rowID) "
                + "requested=\(String(format: "%.3f", restoration.requestedOffset)) "
                + "restored=\(String(format: "%.3f", restoration.restoredOffset)) "
                + "error=\(String(format: "%.3f", restoration.error))"
        } else {
            line = "KAISOLA_NATIVE_TRANSCRIPT_DENSITY_ANCHOR=FAIL "
                + "density=\(density.rawValue) no-mounted-anchor"
        }
        FileHandle.standardOutput.write(Data("\(line)\n".utf8))
        try? FileHandle.standardOutput.synchronize()
    }

    private func emitVisualTranscriptAnchorReceipt(
        _ restoration: AcpTranscriptViewportAnchor.Restoration?,
        failureReason: String
    ) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
              environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "mixed-search" else { return }
        let line: String
        guard let restoration else {
            line = "KAISOLA_NATIVE_TRANSCRIPT_VIEWPORT_ANCHOR=FAIL \(failureReason)"
            FileHandle.standardOutput.write(Data("\(line)\n".utf8))
            try? FileHandle.standardOutput.synchronize()
            return
        }
        line = "KAISOLA_NATIVE_TRANSCRIPT_VIEWPORT_ANCHOR=PASS "
            + "row=\(restoration.rowID) "
            + "requested=\(String(format: "%.3f", restoration.requestedOffset)) "
            + "restored=\(String(format: "%.3f", restoration.restoredOffset)) "
            + "error=\(String(format: "%.3f", restoration.error)) "
            + "hiddenEarlier=\(conversation.hiddenEarlierCount)"
        FileHandle.standardOutput.write(Data("\(line)\n".utf8))
        try? FileHandle.standardOutput.synchronize()
    }

    /// Slash commands matching the draft's leading "/query", ranked by FuzzyMatch.
    private var matchingCommands: [AcpCommand] {
        guard draft.hasPrefix("/"), !conversation.commands.isEmpty else { return [] }
        let query = String(draft.dropFirst()).trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return conversation.commands }
        return conversation.commands
            .compactMap { command -> (AcpCommand, Int)? in
                FuzzyMatch.score(query: query, candidate: command.name).map { (command, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let account = accountAccess.presentation {
                accountRecoveryCard(account)
            } else if !conversation.isConnected, conversation.statusMessage != nil {
                HStack(spacing: 8) {
                    Label("Agent disconnected — your draft and queued follow-ups are preserved.", systemImage: "bolt.slash")
                        .font(.caption)
                        .foregroundStyle(.kaisolaSecondary)
                    Spacer()
                    if conversation.canRestart {
                        Button(conversation.queued.isEmpty ? "Restart" : "Restart & Resume") {
                            Task { await conversation.restart() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                        .help(conversation.queued.isEmpty
                            ? "Start a fresh adapter and resume this ACP session when supported"
                            : "Start a fresh adapter, resume this ACP session when supported, and send the preserved follow-ups in order")
                    } else if conversation.isReconnecting {
                        ProgressView().controlSize(.mini)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Agent disconnected. Your draft and queued follow-ups are preserved.")
            }
            if !matchingCommands.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matchingCommands.prefix(6)) { command in
                        Button {
                            draft = "/\(command.name) "
                        } label: {
                            HStack(spacing: 8) {
                                Text("/\(command.name)").font(.caption.monospaced().weight(.semibold))
                                Text(command.description).font(.caption).foregroundStyle(.kaisolaSecondary).lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            if !conversation.queued.isEmpty {
                queuedStrip
            }
            if !conversation.pendingAttachments.isEmpty {
                attachmentStrip
            }
        AcpComposerCard(
                conversation: conversation,
                draft: $draft,
                focused: $composerFocused,
                attachmentFocused: $attachmentControlFocused,
                attachmentAccessibilityFocused: $attachmentControlAccessibilityFocused,
                isNewConversation: showsEmptyState,
                send: sendDraft,
                onKeyboardFocus: onKeyboardFocus
            )
        }
        .dynamicTypeSize(previewSettings.agentChatTextSize.dynamicTypeSize)
        // The card carries its own border and shadow, so the composer region
        // is a gutter rather than a bar: no divider, no material, nothing that
        // would draw a second edge a few points from the card's own.
        .frame(maxWidth: AcpChatView.composerMaximumWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 13)
        // The drop target and its highlight now live on the whole chat; the
        // composer keeps only paste, which is focus-driven rather than aimed.
        .onPasteCommand(of: [.png, .tiff], perform: handlePaste)
    }

    /// A composer wider than this stops being one object and starts being a
    /// band across the window; the references all cap it well short of a
    /// full-screen pane.
    static let composerMaximumWidth: CGFloat = 860

    /// The invitation that stands in for an empty transcript. It sits low in
    /// the vacated space rather than dead-centre, so the heading and the
    /// composer read as one group and the heading does not visibly jump when
    /// the first message pushes it away.
    private var emptyState: some View {
        VStack(spacing: 0) {
            // Two spacers above, one below: the heading settles about two
            // thirds down, next to the composer rather than marooned in the
            // middle of an empty pane.
            Spacer(minLength: 12)
            Spacer(minLength: 0)
            AcpEmptyStateHeadline(
                heading: AcpEmptyState.heading(
                    projectName: AcpEmptyState.projectName(for: conversation.workspaceURL)
                )
            )
            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("acp.emptyState")
    }

    private func applyFocusRequest(_ generation: UInt64?) {
        guard generation != nil else { return }
        DispatchQueue.main.async {
            composerFocused = true
        }
    }

    private func accountRecoveryCard(
        _ account: ChatAccountAccess.Presentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if account.showsActivityIndicator {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(account.headline)
                } else {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.headline)
                        .font(.caption.weight(.semibold))
                    Text("\(account.provider) · \(account.account)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text(account.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if !account.actions.isEmpty {
                HStack(spacing: 8) {
                    Button(ChatAccountAccess.RecoveryAction.signIn.rawValue, action: onSignIn)
                        .buttonStyle(.borderedProminent)
                    Button(
                        ChatAccountAccess.RecoveryAction.chooseAccount.rawValue,
                        action: onChooseAccount
                    )
                        .buttonStyle(.bordered)
                    Button(
                        ChatAccountAccess.RecoveryAction.preserveTranscript.rawValue,
                        action: onPreserveTranscript
                    )
                        .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(account.headline). \(account.provider) account \(account.account). \(account.detail)")
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(conversation.pendingAttachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.iconName)
                            .font(.caption2).foregroundStyle(.kaisolaSecondary)
                        Text(attachment.name).font(.caption).lineLimit(1)
                        Text(byteLabel(attachment.byteSize))
                            .font(.caption2).foregroundStyle(.kaisolaSecondary)
                        Button {
                            removeAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.kaisolaSecondary)
                        .help("Remove this attachment")
                        .accessibilityLabel(
                            AcpAttachmentAccessibility.removalLabel(name: attachment.name)
                        )
                        .accessibilityIdentifier("acp.attachment.remove.\(attachment.id)")
                        .accessibilityFocused(
                            $accessibilityFocusedAttachmentRemovalID,
                            equals: attachment.id
                        )
                        .focusable()
                        .focused($focusedAttachmentRemovalID, equals: attachment.id)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(
                        AcpAttachmentAccessibility.chipLabel(name: attachment.name)
                    )
                    .accessibilityValue(
                        AcpAttachmentAccessibility.chipValue(byteSize: attachment.byteSize)
                    )
                    .accessibilityIdentifier("acp.attachment.\(attachment.id)")
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollClipDisabled()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func byteLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func removeAttachment(_ attachment: AcpConversation.PendingAttachment) {
        let focusDestination = AcpAttachmentAccessibility.focusDestination(
            removing: attachment.id,
            orderedIDs: conversation.pendingAttachments.map(\.id)
        )
        conversation.removeAttachment(attachment.id)
        let announcement = AcpAttachmentAccessibility.removalAnnouncement(name: attachment.name)

        // Wait until SwiftUI has removed the chip before assigning accessibility
        // focus, otherwise the disappearing button can consume the request.
        DispatchQueue.main.async {
            switch focusDestination {
            case .removalButton(let id):
                attachmentControlFocused = false
                attachmentControlAccessibilityFocused = false
                focusedAttachmentRemovalID = id
                accessibilityFocusedAttachmentRemovalID = id
            case .attachmentControl:
                focusedAttachmentRemovalID = nil
                accessibilityFocusedAttachmentRemovalID = nil
                // Removing the last chip also removes the strip that precedes
                // the composer, which rebuilds the native menu control. Assign
                // its focus on the following turn so the new control, rather
                // than the disappearing hierarchy, consumes the request.
                DispatchQueue.main.async {
                    attachmentControlFocused = true
                    attachmentControlAccessibilityFocused = true
                }
            }
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: announcement,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
    }

    /// Stage files dropped onto the composer.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [conversation] data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in conversation.prepareAttachment(fileURL: url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                // The macOS screenshot thumbnail — the drag most worth
                // catching — offers image data behind a file promise, never a
                // plain file URL, so the fileURL-only net dropped exactly the
                // drag people make right after taking a screenshot.
                handled = true
                let typeID = provider.registeredTypeIdentifiers.first {
                    UTType($0)?.conforms(to: .image) == true
                } ?? UTType.png.identifier
                let suggested = provider.suggestedName
                _ = provider.loadDataRepresentation(forTypeIdentifier: typeID) { [conversation] data, _ in
                    guard let data, let image = NSImage(data: data),
                          let png = image.pngRepresentation() else { return }
                    let base = (suggested as NSString?)?.deletingPathExtension
                    let name = (base?.isEmpty == false ? base! : "Dropped image") + ".png"
                    Task { @MainActor in conversation.addImageData(png, name: name) }
                }
            }
        }
        return handled
    }

    /// Stage a pasted image, read from the general pasteboard and normalized to
    /// PNG. Fires only for image content types, so pasting text into the field
    /// is untouched.
    private func handlePaste(_ providers: [NSItemProvider]) {
        guard let image = NSImage(pasteboard: .general), let png = image.pngRepresentation() else { return }
        conversation.addImageData(png, name: "Pasted image.png")
    }

    private var queuedStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            if conversation.isConnected, !conversation.isRunning {
                HStack(spacing: 8) {
                    Text("\(conversation.queued.count) preserved follow-up\(conversation.queued.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.kaisolaSecondary)
                    Spacer()
                    Button("Resume All") {
                        conversation.resumeQueuedFollowUps()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .help("Send the preserved follow-ups one at a time in their original order")
                    .accessibilityLabel("Resume all queued follow-ups")
                }
                .padding(.horizontal, 8)
            }
            ForEach(conversation.queued) { message in
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.caption2).foregroundStyle(.kaisolaSecondary)
                    Text(message.text).font(.caption).lineLimit(1)
                    Spacer()
                    // Identified so the row's own contents, and whether it is
                    // currently offering the steer action, are inspectable.
                    // Offered only while a steering-capable adapter has a turn
                    // running — the one window in which the request can do what
                    // the button says. Otherwise this stays a plain queued row.
                    if conversation.canInjectQueued
                        || conversation.injectingQueuedIDs.contains(message.id) {
                        Button {
                            conversation.injectQueued(message.id)
                        } label: {
                            Image(systemName: "bolt.fill").font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(KaisolaStatusTone.needsYou.foregroundColor)
                        .disabled(conversation.injectingQueuedIDs.contains(message.id))
                        .help("Steer: send this into the running turn now")
                        .accessibilityIdentifier("acp.queued.\(message.id).steer")
                        .accessibilityLabel("Steer this queued follow-up into the running turn")
                    }
                    Button {
                        conversation.removeQueued(message.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.kaisolaSecondary)
                    .disabled(conversation.injectingQueuedIDs.contains(message.id))
                    .help("Remove this queued follow-up")
                    .accessibilityIdentifier("acp.queued.\(message.id).remove")
                    .accessibilityLabel("Remove this queued follow-up")
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("acp.queued.\(message.id)")
                .accessibilityLabel("Queued follow-up: \(message.text)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sendDraft() {
        let text = draft
        if conversation.send(text) {
            draft = ""
        }
    }
}

/// Rendering budgets keep hostile or accidental multi-megabyte agent output
/// from monopolizing SwiftUI layout/Markdown parsing. The full transcript stays
/// in the conversation/store; only the visible representation is bounded.
struct AcpBoundedText: Equatable, Sendable {
    let text: String
    let isTruncated: Bool
}

enum AcpChatRendering {
    static let assistantCharacterLimit = 120_000
    static let assistantLineLimit = 2_500
    static let toolCharacterLimit = 64_000
    static let toolLineLimit = 1_500
    static let diffCharacterLimit = 100_000
    static let diffLineLimit = 2_000

    static func bounded(
        _ text: String,
        characterLimit: Int,
        lineLimit: Int
    ) -> AcpBoundedText {
        guard characterLimit > 0, lineLimit > 0 else {
            return AcpBoundedText(text: "", isTruncated: !text.isEmpty)
        }

        let prefix = text.prefix(characterLimit)
        var result = String(prefix)
        var truncated = prefix.endIndex != text.endIndex
        var currentLine = 1
        var lineCutoff: String.Index?
        for index in result.indices where result[index] == "\n" {
            if currentLine >= lineLimit {
                lineCutoff = index
                break
            }
            currentLine += 1
        }
        if let lineCutoff {
            result = String(result[..<lineCutoff])
            truncated = true
        }
        return AcpBoundedText(text: result, isTruncated: truncated)
    }

    static func expandedLimit(_ current: Int) -> Int {
        current > Int.max / 2 ? Int.max : current * 2
    }
}

struct ToolCallDensityPresentation: Equatable, Sendable {
    let call: AcpToolCall
    let density: ToolCallDensity

    var statusLabel: String {
        switch call.status {
        case .pending: "Pending"
        case .inProgress: "In progress"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    var affectedFiles: [String] { call.declaredFilePaths }
    var artifactCount: Int { call.content.count }
    var hasExpandableContent: Bool { artifactCount > 0 }

    var visibleDetailLevel: Int {
        switch density {
        case .compact: 1
        case .balanced: 2
        case .detailed: 3
        }
    }

    /// Only the Detailed density annotates collapsed rows. Compact and
    /// Balanced keep a collapsed call to its single line — the log-line
    /// contract — and reveal counts and paths behind the disclosure.
    var showsArtifactSummary: Bool { density == .detailed }
    var showsAffectedFilesWhenCollapsed: Bool { density == .detailed }
    var wrapsAffectedFiles: Bool { density == .detailed }
    var expandsArtifactsByDefault: Bool { false }

    var accessibilityOrder: [String] {
        [
            statusLabel,
            call.title,
            call.kind,
            affectedFiles.isEmpty
                ? "No affected files"
                : "Affected files: \(affectedFiles.joined(separator: ", "))",
            artifactCount == 1
                ? "1 expandable artifact"
                : "\(artifactCount) expandable artifacts",
        ]
    }

    /// Spacing between a row's header and whatever detail it shows — the
    /// files line, the artifact count, or the expanded artifacts. The old
    /// `cardPadding` died with the card itself.
    var cardSpacing: CGFloat {
        switch density {
        case .compact: 4
        case .balanced: 6
        case .detailed: 8
        }
    }
}

/// One quiet line for a harness-injected background-task notification. The
/// full XML stays reachable (selection and the export path keep the raw
/// text); the stream shows only the line a reader might care about.
struct HarnessNoticeRow: View {
    let summary: String
    let fullText: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.badge.checkmark")
                .accessibilityHidden(true)
            Text(summary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(fullText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Background task notification: \(summary)")
    }
}

struct TranscriptRowView: View {
    let row: AcpTranscriptRow
    var workspaceURL: URL?
    var retry: ((String) -> Void)?
    var terminalSnapshot: (@Sendable (String) async -> AcpTerminalHost.Snapshot?)?
    /// True for the message that closes a turn. Interim narration renders as
    /// plain prose; only the turn's final answer carries the response
    /// affordances (Copy response).
    var showsResponseChrome = true
    /// Present in chat panes, where a watched subagent floats as a card over
    /// the workspace; absent elsewhere (Mesh), where the chip keeps its
    /// anchored popover.
    var onWatchSubagent: ((AcpSubagentWatchTarget) -> Void)?
    /// Whether the conversation is still running. A backgrounded subagent's
    /// chip may only claim live work while the turn that spawned it is alive;
    /// after that the honest word is past tense.
    var conversationIsRunning = true

    var body: some View {
        switch row {
        case let .runProfileAudit(_, profile):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .accessibilityHidden(true)
                Text("Run profile: \(profile.name)")
                if let model = profile.modelID { Text("· \(model)") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Run profile audit: \(profile.name)")
        case let .user(_, text, failed):
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if failed {
                    Button {
                        retry?(row.id)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .help("This message failed to send — try again")
                }
                // Capped, not guttered: the old 40pt gutter turned a message
                // on a wide pane into a full-width band. The bubble hugs its
                // text up to the cap and wraps past it.
                Text(text)
                    .padding(.horizontal, AcpBubble.horizontalPadding)
                    .padding(.vertical, AcpBubble.verticalPadding)
                    .background(
                        failed ? Color.red.opacity(0.12) : AcpBubble.userFill,
                        in: RoundedRectangle(cornerRadius: AcpBubble.cornerRadius, style: .continuous)
                    )
                    .overlay {
                        if failed {
                            RoundedRectangle(cornerRadius: AcpBubble.cornerRadius, style: .continuous)
                                .strokeBorder(.red.opacity(0.5))
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: AcpBubble.maximumWidth, alignment: .trailing)
            }
            // Identified so the user's own side of the transcript — including a
            // prompt restored from a resumed thread, and a message steered into
            // a running turn — is inspectable.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("acp.transcript.\(row.id)")
            .accessibilityLabel("You said: \(text)")
        case let .message(_, text):
            VStack(alignment: .leading, spacing: 6) {
                // The turn's final answer announces itself. Interim narration
                // flows as plain prose; the one message that closes the
                // exchange carries the title, so "where is the actual answer"
                // has a visible landmark again (2026-08-26 feedback).
                if showsResponseChrome {
                    Text("Response")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                AssistantMarkdownText(
                    text: text,
                    workspaceURL: workspaceURL,
                    showsCopyButton: showsResponseChrome
                )
            }
            // The turn's final answer is the heading landmark VoiceOver's
            // rotor steps between.
            .accessibilityAddTraits(showsResponseChrome ? .isHeader : [])
        case let .thought(_, text):
            // The quote block's left rule, in tertiary ink: an expanded
            // thought must stay separable from the answer around it.
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.kaisolaTertiary)
                    .frame(width: 3)
                    .accessibilityHidden(true)
                DisclosureGroup {
                    let bounded = AcpChatRendering.bounded(
                        text,
                        characterLimit: AcpChatRendering.assistantCharacterLimit,
                        lineLimit: AcpChatRendering.assistantLineLimit
                    )
                    Text(bounded.text)
                        .font(.callout)
                        .foregroundStyle(.kaisolaSecondary)
                        .textSelection(.enabled)
                    if bounded.isTruncated {
                        Text("Thinking output truncated in this view")
                            .font(.caption2)
                            .foregroundStyle(.kaisolaSecondary)
                    }
                } label: {
                    Label("Thinking", systemImage: "brain")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.kaisolaSecondary)
                }
            }
        case let .tool(call):
            switch AcpDelegatedWork.classify(call) {
            case let .subagent(phase):
                SubagentChipRow(
                    call: call,
                    phase: phase,
                    workspaceURL: workspaceURL,
                    turnIsLive: conversationIsRunning,
                    onWatch: onWatchSubagent
                )
            case .compaction:
                CompactionRow(status: call.status)
            case nil:
                ToolCallCard(
                    call: call,
                    workspaceURL: workspaceURL,
                    terminalSnapshot: terminalSnapshot
                )
            }
        case let .plan(_, entries):
            PlanCard(entries: entries)
        case let .permissionDecision(_, text):
            Label {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "shield.slash")
                    .foregroundStyle(.orange)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("acp.transcript.\(row.id)")
        }
    }
}

extension AcpTranscriptRow {
    enum TranscriptSection: Equatable {
        case user
        case work
        case response
    }

    var transcriptSection: TranscriptSection {
        switch self {
        case .user: .user
        case .message: .response
        case .runProfileAudit, .thought, .tool, .plan, .permissionDecision: .work
        }
    }

    /// Which voice of the transcript's vertical rhythm the row speaks in.
    /// Work rows share `transcriptSection == .work` exactly, so the tight
    /// work-run spacing and the "Agent work" label always describe the same
    /// set of rows.
    var rhythmKind: AcpTranscriptMetrics.RowKind {
        switch transcriptSection {
        case .user: .user
        case .response: .assistant
        case .work: .work
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// One spoken contract for the tool header. The visible row contains a status
/// symbol, kind tag, title, and disclosure chevron; exposing those children
/// separately made the symbol-derived button name opaque and left status
/// changes silent. Keep the description bounded to metadata already visible in
/// the row — artifact contents may contain sensitive output and are available
/// only after the user opens the disclosure.
struct ToolCallAccessibility: Equatable {
    let label: String
    let value: String
    let actionName: String?
    let identifier: String

    init(call: AcpToolCall, expanded: Bool) {
        let artifactCount = call.content.count
        let artifactLabel = "\(artifactCount) artifact\(artifactCount == 1 ? "" : "s")"
        let statusLabel: String
        switch call.status {
        case .pending: statusLabel = "Pending"
        case .inProgress: statusLabel = "In progress"
        case .completed: statusLabel = "Completed"
        case .failed: statusLabel = "Failed"
        }

        if artifactCount > 0 {
            let disclosureLabel = expanded ? "Hide details" : "Show details"
            label = "\(disclosureLabel) for \(call.title)"
            value = "\(call.kind) tool, \(statusLabel), \(artifactLabel), \(expanded ? "Expanded" : "Collapsed")"
            actionName = disclosureLabel
        } else {
            label = call.title
            value = "\(call.kind) tool, \(statusLabel), \(artifactLabel)"
            actionName = nil
        }
        identifier = "acp.tool.\(call.id)"
    }
}

/// `.defaultScrollAnchor(.bottom, for: .initialOffset)` where the OS has the
/// scoped form; the unscoped anchor below macOS 15 also re-anchors on size
/// changes, which is tolerable there and correct nowhere else.
private struct TranscriptBottomAnchorModifier: ViewModifier {
    /// While the reader's intent is "follow the stream", the scroll view keeps
    /// the tail pinned through every content-size change natively, instead of
    /// chasing it with discrete `scrollTo` hops. The hops fired ~80ms apart,
    /// and every frame between two of them could show the tail mid-flight —
    /// rows sliced at the viewport edge, then yanked. The coalesced pin stays
    /// as a correction pass; the anchor does the per-frame work. A reader who
    /// scrolls up drops the size-change anchor entirely, so history holds
    /// still while the stream grows below.
    var followsTail: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(followsTail ? .bottom : nil, for: .sizeChanges)
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}

/// The transcript's top edge, under the pane header: on macOS 26 the system's
/// soft scroll-edge treatment eases rows out instead of guillotining them at
/// the clip line; earlier systems keep the plain edge.
private struct TranscriptTopEdgeModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// One quiet line per burst of tool work — "Ran 4 commands, read 2 files" —
/// with the call-by-call log behind a click, the way the Codex app writes a
/// turn. The marker is the collapsed state and the default: the stream shows
/// the occasional prose and thoughts, not the machinery.
struct WorkRunMarkerRow: View {
    let calls: [AcpToolCall]
    let expanded: Bool
    var workspaceURL: URL?
    var terminalSnapshot: (@Sendable (String) async -> AcpTerminalHost.Snapshot?)?
    let toggle: () -> Void

    var body: some View {
        let summary = AcpWorkRunSummary(calls: calls)
        return VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.kaisolaTertiary)
                        .frame(width: 13)
                        .accessibilityHidden(true)
                    // No failure suffix on the collapsed line (2026-08-26):
                    // a red "2 failed" turned every benign non-zero exit — a
                    // grep with no matches, a probe that said no — into an
                    // alarm on the quiet summary. The call-by-call log behind
                    // the click still marks each failed call in red.
                    Text(summary.label)
                        .font(.callout)
                        .foregroundStyle(.kaisolaSecondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.label)
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            .accessibilityHint("Shows the call-by-call log")
            .accessibilityIdentifier("acp.workrun.\(calls.first?.id ?? "empty")")
            .accessibilityAddTraits(.isButton)

            if expanded {
                VStack(alignment: .leading, spacing: AcpTranscriptMetrics.workRunSpacing) {
                    ForEach(calls) { call in
                        ToolCallCard(
                            call: call,
                            workspaceURL: workspaceURL,
                            terminalSnapshot: terminalSnapshot
                        )
                        // Keep the row-prefixed id addressable so search
                        // navigation can land on a call inside an opened run.
                        .id(AcpTranscriptRow.tool(call).id)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.vertical, 1)
    }
}

/// A spawned subagent, as the Codex app draws one: a small pill with the
/// job's name and its state, visually distinct from the flat run of tool log
/// lines around it — one row of the transcript is a whole other agent, and it
/// should not dress like a shell command. A foreground spawn's chip carries
/// "working…" while its tool call is open and discloses the returned report
/// when it lands; a background spawn honestly says "in background", because
/// the stream never reports a detached agent's completion.
struct SubagentChipRow: View {
    let call: AcpToolCall
    let phase: AcpSubagentPhase
    var workspaceURL: URL?
    /// False once the turn that spawned this agent has ended. "in background"
    /// is a live claim; a finished turn's detached spawn reads "delegated" —
    /// the stream never says whether it completed, and the chip must not
    /// pretend to know.
    var turnIsLive = true
    /// When set, watching opens the floating workspace card; when nil the
    /// chip falls back to its anchored popover.
    var onWatch: ((AcpSubagentWatchTarget) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var showsActivity = false

    private var statusText: String {
        phase == .backgrounded && !turnIsLive ? "delegated" : phase.statusWord
    }

    /// The launch acknowledgement on a backgrounded spawn is adapter
    /// plumbing, not a report; there is nothing worth disclosing.
    private var hasReport: Bool {
        guard phase == .finished || phase == .failed else { return false }
        return call.content.contains { if case .text = $0 { return true } else { return false } }
    }

    /// The detached agent's own transcript, when the launch acknowledgement
    /// named one. This is what makes the chip a window, not a label: click it
    /// and watch what the subagent is doing.
    private var activityFileURL: URL? {
        AcpSubagentActivity.outputFileURL(from: call)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if let url = activityFileURL, hasReport == false || phase == .backgrounded {
                    if let onWatch {
                        onWatch(AcpSubagentWatchTarget(id: call.id, title: call.title, fileURL: url))
                    } else {
                        showsActivity.toggle()
                    }
                } else if hasReport {
                    expanded.toggle()
                }
            } label: {
                chip
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsActivity, arrowEdge: .bottom) {
                if let url = activityFileURL {
                    SubagentActivityView(title: call.title, fileURL: url)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Subagent: \(call.title)")
            .accessibilityValue(statusText + (hasReport ? (expanded ? ", expanded" : ", report available") : (activityFileURL != nil ? ", activity available" : "")))
            .accessibilityIdentifier("acp.subagent.\(call.id)")
            .accessibilityAddTraits((hasReport || activityFileURL != nil) ? [.isButton, .updatesFrequently] : [.updatesFrequently])

            if expanded {
                ForEach(call.content) { artifact in
                    if case let .text(text) = artifact {
                        ToolTextArtifact(text: text)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .environment(\.openURL, OpenURLAction { link in
            AcpTranscriptLinkRouting.open(link, workspaceURL: workspaceURL)
        })
    }

    private var chip: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(iconColor)
                .symbolEffect(
                    .pulse,
                    options: .repeating,
                    isActive: !reduceMotion && phase == .working
                )
                .accessibilityHidden(true)
            Text(call.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(phase == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.kaisolaSecondary))
            if activityFileURL != nil, phase == .backgrounded || phase == .working {
                // The spoken invitation, not a mystery glyph: a detached
                // agent's chip says it can be watched.
                Label("watch", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .labelStyle(.titleAndIcon)
            } else if hasReport {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.kaisolaSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // A pill of Liquid Glass (material below macOS 26), not a grey wash —
        // the Codex reference chips are white-led. The failed wash is an
        // explicit layer because the control surface's tint channel only
        // exists on the macOS 26 branch, and a failed chip must differ on
        // every OS and under Reduce Transparency.
        .background {
            if phase == .failed {
                RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius, style: .continuous)
                    .fill(.red.opacity(0.08))
            }
        }
        .kaisolaControlSurface(active: phase == .working)
        .contentShape(RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius, style: .continuous))
    }

    private var iconColor: Color {
        switch phase {
        case .working: .accentColor
        case .backgrounded, .finished: .kaisolaSecondary
        case .failed: .red
        }
    }
}

/// The live window onto a detached subagent: the tail of its harness
/// transcript, refreshed every two seconds while open, with a freshness line
/// so "is it working" has an answer at a glance.
/// One watched subagent: identity so a second watch replaces the first, the
/// title for the card header, and the transcript file the feed tails.
struct AcpSubagentWatchTarget: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let fileURL: URL
}

/// The live tail of a subagent's transcript — freshness dot, recent actions,
/// reveal-in-Finder — shared by the floating watch card and the popover
/// fallback. Polls the file every two seconds while mounted.
private struct SubagentActivityFeed: View {
    let fileURL: URL
    @State private var actions: [String] = []
    @State private var lastModified: Date?
    @State private var fileMissing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            freshnessLine
            Divider()
            if actions.isEmpty {
                Text(fileMissing
                    ? "No transcript yet — the agent may still be starting."
                    : "Nothing readable in the transcript yet.")
                    .font(.callout)
                    .foregroundStyle(.kaisolaSecondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                        Text(action)
                            .font(.callout)
                            .foregroundStyle(index == actions.count - 1
                                ? AnyShapeStyle(.primary)
                                : AnyShapeStyle(.kaisolaSecondary))
                            .lineLimit(2)
                    }
                }
            }
            Divider()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } label: {
                Label("Reveal transcript in Finder", systemImage: "folder")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .task(id: fileURL) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private var freshnessLine: some View {
        if let lastModified {
            let age = Date().timeIntervalSince(lastModified)
            HStack(spacing: 5) {
                Circle()
                    .fill(age < 10 ? Color.green : Color.kaisolaTertiary)
                    .frame(width: 7, height: 7)
                Text(age < 10
                    ? "Writing right now"
                    : "Last wrote \(Self.ago(age)) ago")
                    .font(.caption)
                    .foregroundStyle(.kaisolaSecondary)
            }
        }
    }

    private static func ago(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    private func refresh() async {
        let url = fileURL
        let result: ([String], Date?, Bool) = await Task.detached(priority: .utility) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let handle = try? FileHandle(forReadingFrom: url) else {
                return ([], nil, true)
            }
            defer { try? handle.close() }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = attributes[.modificationDate] as? Date
            let tailLength: Int64 = 65_536
            if size > tailLength { try? handle.seek(toOffset: UInt64(size - tailLength)) }
            let data = (try? handle.readToEnd()) ?? Data()
            return (AcpSubagentActivity.recentActions(fromTail: data), modified, false)
        }.value
        actions = result.0
        lastModified = result.1
        fileMissing = result.2
    }
}

/// The anchored-popover presentation of a subagent's activity, kept for
/// embedders without a workspace to float a card over (Mesh columns).
private struct SubagentActivityView: View {
    let title: String
    let fileURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            SubagentActivityFeed(fileURL: fileURL)
        }
        .padding(14)
        .frame(width: 400, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("acp.subagent.activity")
    }
}

/// A watched subagent as a real surface: a floating glass card popped over
/// the chat workspace, in the grammar Landmarks uses for its floating badge
/// stack — a card over content, opened and dismissed in place. It replaces
/// the anchored popover for chats, which vanished on any outside click and
/// could never be *kept* open beside the stream it was watching.
private struct SubagentWatchCard: View {
    let target: AcpSubagentWatchTarget
    let close: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: KaisolaVisualSystem.insetRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(target.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.kaisolaTertiary)
                }
                .buttonStyle(.plain)
                .help("Close the watch card")
                .accessibilityLabel("Close subagent watch")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 9)
            Divider()
            // The feed scrolls inside the card, so a chatty subagent grows a
            // scrollbar rather than a tower.
            ScrollView {
                SubagentActivityFeed(fileURL: target.fileURL)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 420)
        .modifier(SubagentWatchCardChrome(shape: shape, reduceTransparency: reduceTransparency))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("acp.subagent.watchCard")
    }
}

/// Liquid Glass on macOS 26, a material below, a clean solid under Reduce
/// Transparency — the control-surface ladder at card size, with the floating
/// card's own shadow.
private struct SubagentWatchCardChrome: ViewModifier {
    let shape: RoundedRectangle
    let reduceTransparency: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        surfaced(content)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: KaisolaVisualSystem.hairline))
            .shadow(
                color: .black.opacity(0.18),
                radius: ChromeCardElevation.shadowRadius,
                y: ChromeCardElevation.shadowOffsetY
            )
    }

    @ViewBuilder
    private func surfaced(_ content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
            #else
            content.background(.regularMaterial, in: shape)
            #endif
        }
    }
}

/// Context compaction is housekeeping, not work: one tertiary line, the way
/// the Codex app writes "Context automatically compacting".
struct CompactionRow: View {
    let status: AcpToolCall.Status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var text: String {
        status == .completed ? "Context compacted" : "Compacting context…"
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "rectangle.compress.vertical")
                .font(.system(size: 11))
                .symbolEffect(
                    .pulse,
                    options: .repeating,
                    isActive: !reduceMotion && status != .completed
                )
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(.kaisolaTertiary)
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

/// A tool call is a log line, not a card. The reference surfaces — Claude
/// Code, the Codex app — write agent work as a run of quiet one-line entries
/// between paragraphs of prose; the old full-width filled box per call turned
/// every turn into a wall of grey rectangles, with the artifact paths spelled
/// out under each one. The box, its padding, and the always-on affected-files
/// line are gone: a collapsed call is one slim row, and everything heavier
/// waits behind the disclosure.
struct ToolCallCard: View {
    let call: AcpToolCall
    var workspaceURL: URL?
    var terminalSnapshot: (@Sendable (String) async -> AcpTerminalHost.Snapshot?)?
    @ObservedObject private var settings = NativePreviewSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var hovered = false

    /// Aligns expanded detail under the title, past the status glyph and kind
    /// tag, the way Claude Code indents a call's result under its bullet.
    private static let detailIndent: CGFloat = 20

    private var density: ToolCallDensity { settings.toolCallDensity }
    private var presentation: ToolCallDensityPresentation {
        ToolCallDensityPresentation(call: call, density: density)
    }
    private var hasArtifacts: Bool { presentation.hasExpandableContent }
    private var accessibility: ToolCallAccessibility {
        ToolCallAccessibility(call: call, expanded: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: presentation.cardSpacing) {
            if hasArtifacts {
                Button {
                    expanded.toggle()
                } label: {
                    header
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibility.label)
                .accessibilityValue(accessibility.value)
                .accessibilityIdentifier(accessibility.identifier)
                .accessibilityAddTraits([.isButton, .updatesFrequently])
            } else {
                header
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibility.label)
                    .accessibilityValue(accessibility.value)
                    .accessibilityIdentifier(accessibility.identifier)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            // The paths live behind the disclosure now (or in the Detailed
            // density, which asks for them): the title already names what the
            // call touched, and a second line of raw links under every row was
            // most of what made the transcript read as machinery.
            if !presentation.affectedFiles.isEmpty,
               expanded || presentation.showsAffectedFilesWhenCollapsed {
                Text(AcpTranscriptInlineRendering.attributed(
                    presentation.affectedFiles.joined(separator: ", "),
                    workspaceURL: workspaceURL
                ))
                    .font(.caption)
                    .foregroundStyle(.kaisolaSecondary)
                    .lineLimit(presentation.wrapsAffectedFiles ? nil : 1)
                    .truncationMode(.middle)
                    .padding(.leading, Self.detailIndent)
                    .accessibilityLabel(presentation.accessibilityOrder[3])
            }

            if presentation.showsArtifactSummary, hasArtifacts, !expanded {
                Text(
                    presentation.artifactCount == 1
                        ? "1 artifact"
                        : "\(presentation.artifactCount) artifacts"
                )
                .font(.caption2)
                .foregroundStyle(.kaisolaSecondary)
                .padding(.leading, Self.detailIndent)
                .accessibilityLabel(presentation.accessibilityOrder[4])
            }

            if expanded {
                ForEach(call.content) { artifact in
                    switch artifact {
                    case let .diff(path, oldText, newText):
                        DiffView(path: path, oldText: oldText, newText: newText)
                    case let .text(text):
                        ToolTextArtifact(text: text)
                    case let .terminal(id):
                        TerminalContentView(terminalID: id, snapshot: terminalSnapshot)
                    }
                }
                .padding(.leading, Self.detailIndent)
            }
        }
        .padding(.vertical, 1)
        .background { rowWash }
        .onHover { hovered = $0 }
        .environment(\.openURL, OpenURLAction { link in
            AcpTranscriptLinkRouting.open(link, workspaceURL: workspaceURL)
        })
    }

    /// The only fills a row carries, bled a few points into the page margin so
    /// the row's text stays on the prose's left edge. Failure keeps a standing
    /// wash — a failed call must differ from a completed one by more than one
    /// red glyph — and hover earns a whisper of surface on expandable rows.
    @ViewBuilder
    private var rowWash: some View {
        if call.status == .failed {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.red.opacity(0.07))
                .padding(.horizontal, -7)
        } else if hovered, hasArtifacts {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary.opacity(0.35))
                .padding(.horizontal, -7)
        }
    }

    private var header: some View {
        HStack(spacing: density == .compact ? 6 : 9) {
            Image(systemName: statusSymbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: 13)
                .symbolEffect(
                    .pulse,
                    options: .repeating,
                    isActive: !reduceMotion && call.status == .inProgress
                )
                .accessibilityHidden(true)
            // The symbol already carries the status, so no status word: the
            // kind leads instead, and a column of chips scans as a left-aligned
            // kind column rather than a ragged right one. VoiceOver keeps the
            // full status via `ToolCallAccessibility`.
            Text(call.kind)
                .font(.caption.monospaced())
                .foregroundStyle(.kaisolaSecondary)
            Text(call.title)
                .font(.callout)
                .foregroundStyle(call.status == .failed ? AnyShapeStyle(.primary) : AnyShapeStyle(.kaisolaSecondary))
                .lineLimit(density == .detailed ? 2 : 1)
                .truncationMode(.middle)
            Spacer()
            if hasArtifacts {
                // Present only while the pointer is near or the row is open:
                // a chevron on every line of a forty-call run is forty
                // chevrons. The hover wash and the AX value carry the
                // affordance the rest of the time.
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2).foregroundStyle(.kaisolaSecondary)
                    .opacity(hovered || expanded ? 1 : 0)
            }
        }
        .contentShape(Rectangle())
    }

    private var statusSymbol: String {
        switch call.status {
        case .pending, .inProgress: "gearshape"
        case .completed: "checkmark.circle"
        case .failed: "xmark.circle"
        }
    }

    private var statusColor: Color {
        switch call.status {
        case .pending, .inProgress: .kaisolaSecondary
        case .completed: .green
        case .failed: .red
        }
    }
}

private struct ToolTextArtifact: View {
    let text: String
    @State private var characterLimit = AcpChatRendering.toolCharacterLimit
    @State private var lineLimit = AcpChatRendering.toolLineLimit

    private var rendered: AcpBoundedText {
        AcpChatRendering.bounded(
            text,
            characterLimit: characterLimit,
            lineLimit: lineLimit
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                Text(rendered.text.isEmpty ? " " : rendered.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 220)
            HStack(spacing: 9) {
                if rendered.isTruncated {
                    Button("Show more") {
                        characterLimit = AcpChatRendering.expandedLimit(characterLimit)
                        lineLimit = AcpChatRendering.expandedLimit(lineLimit)
                    }
                    .font(.caption2.weight(.semibold))
                    .help("Render the next bounded portion of this tool output")
                }
                if characterLimit > AcpChatRendering.toolCharacterLimit {
                    Button("Collapse") {
                        characterLimit = AcpChatRendering.toolCharacterLimit
                        lineLimit = AcpChatRendering.toolLineLimit
                    }
                    .font(.caption2)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy output", systemImage: "doc.on.doc")
                }
                .font(.caption2)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            if rendered.isTruncated {
                Text("A bounded prefix is shown; the complete tool output remains available.")
                    .font(.caption2)
                    .foregroundStyle(.kaisolaSecondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
        }
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Live output of an agent-spawned terminal inside a tool card: polls the
/// AcpTerminalHost snapshot until the process exits.
@MainActor
final class AcpTerminalContentModel: ObservableObject {
    enum Status: Equatable {
        case running
        case exited(String)
        case unavailable

        var label: String {
            switch self {
            case .running: "Running…"
            case let .exited(label): label
            case .unavailable: "Terminal output unavailable"
            }
        }
    }

    @Published private(set) var output = ""
    @Published private(set) var outputIsTruncated = false
    @Published private(set) var status: Status = .running

    private let pollIntervalNanoseconds: UInt64
    private var activeTerminalID: String?
    private var pollGeneration: UInt64 = 0

    init(pollIntervalNanoseconds: UInt64 = 700_000_000) {
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    func poll(
        terminalID: String,
        snapshot: (@Sendable (String) async -> AcpTerminalHost.Snapshot?)?
    ) async {
        pollGeneration &+= 1
        let generation = pollGeneration
        if activeTerminalID != terminalID {
            activeTerminalID = terminalID
            output = ""
            outputIsTruncated = false
        }
        status = .running

        while !Task.isCancelled {
            let next = await snapshot?(terminalID)
            guard !Task.isCancelled, pollGeneration == generation else { return }
            guard let next else {
                status = .unavailable
                return
            }

            let bounded = AcpChatRendering.bounded(
                next.output,
                characterLimit: AcpChatRendering.toolCharacterLimit,
                lineLimit: AcpChatRendering.toolLineLimit
            )
            output = bounded.text
            outputIsTruncated = next.truncated || bounded.isTruncated
            if let exitStatus = next.exitStatus {
                status = .exited(
                    exitStatus.exitCode.map { "Exited (\($0))" }
                        ?? exitStatus.signal.map { "Killed (\($0))" }
                        ?? "Exited"
                )
                return
            }

            if pollIntervalNanoseconds == 0 {
                await Task.yield()
            } else {
                do {
                    try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    /// Invalidates an in-flight provider call that may ignore task cancellation.
    func invalidate() {
        pollGeneration &+= 1
    }
}

struct TerminalContentView: View {
    let terminalID: String
    var snapshot: (@Sendable (String) async -> AcpTerminalHost.Snapshot?)?
    @StateObject private var model = AcpTerminalContentModel()
    @State private var retryGeneration: UInt64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.caption2)
                Text(model.status.label).font(.caption2)
                Spacer()
                if model.status == .unavailable {
                    Button {
                        retryGeneration &+= 1
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2.weight(.semibold))
                    .help("Try to load this terminal's output again")
                }
            }
            .foregroundStyle(statusColor)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary.opacity(0.6))
            ScrollView {
                Text(model.output.isEmpty ? " " : model.output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 180)
            .background(.black.opacity(0.18))
            if model.status == .unavailable {
                Text("No snapshot was returned for \(terminalID). The terminal may have been released or its output evicted.")
                    .font(.caption2)
                    .foregroundStyle(.kaisolaSecondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
            if model.outputIsTruncated {
                Text("Earlier terminal output truncated in this view")
                    .font(.caption2)
                    .foregroundStyle(.kaisolaSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(.quaternary, lineWidth: KaisolaVisualSystem.hairline))
        .task(id: PollIdentity(terminalID: terminalID, retryGeneration: retryGeneration)) {
            await model.poll(terminalID: terminalID, snapshot: snapshot)
        }
        .onDisappear {
            model.invalidate()
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .running: KaisolaStatusTone.working.foregroundColor
        case .unavailable: KaisolaStatusTone.needsYou.foregroundColor
        case .exited: .kaisolaSecondary
        }
    }

    private struct PollIdentity: Hashable {
        let terminalID: String
        let retryGeneration: UInt64
    }
}

/// A compact diff for a tool-call file edit: removed lines tinted red, added
/// lines green, with word-level highlights on changed line pairs and a
/// unified ↔ side-by-side toggle — mirroring the Electron chat's diff card.
struct DiffView: View {
    let path: String
    let oldText: String?
    let newText: String

    @State private var sideBySide = false
    @State private var characterLimit = AcpChatRendering.diffCharacterLimit
    @State private var lineLimit = AcpChatRendering.diffLineLimit

    private var boundedOld: AcpBoundedText {
        AcpChatRendering.bounded(
            oldText ?? "",
            characterLimit: characterLimit,
            lineLimit: lineLimit
        )
    }

    private var boundedNew: AcpBoundedText {
        AcpChatRendering.bounded(
            newText,
            characterLimit: characterLimit,
            lineLimit: lineLimit
        )
    }

    private var rows: [AcpDiff.Row] {
        AcpDiff.rows(old: boundedOld.text, new: boundedNew.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text((path as NSString).lastPathComponent)
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    sideBySide.toggle()
                } label: {
                    Image(systemName: sideBySide ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.kaisolaSecondary)
                .help(sideBySide ? "Unified view" : "Side-by-side view")
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary.opacity(0.6))
            if sideBySide {
                splitBody
            } else {
                unifiedBody
            }
            if boundedOld.isTruncated || boundedNew.isTruncated
                || characterLimit > AcpChatRendering.diffCharacterLimit {
                VStack(alignment: .leading, spacing: 5) {
                    if boundedOld.isTruncated || boundedNew.isTruncated {
                        Label(
                            "A bounded diff prefix is shown; the complete artifact remains available.",
                            systemImage: "ellipsis.rectangle"
                        )
                        .font(.caption2)
                        .foregroundStyle(.kaisolaSecondary)
                    }
                    HStack(spacing: 10) {
                        if boundedOld.isTruncated || boundedNew.isTruncated {
                            Button("Show more") {
                                characterLimit = AcpChatRendering.expandedLimit(characterLimit)
                                lineLimit = AcpChatRendering.expandedLimit(lineLimit)
                            }
                            .font(.caption2.weight(.semibold))
                        }
                        if characterLimit > AcpChatRendering.diffCharacterLimit {
                            Button("Collapse") {
                                characterLimit = AcpChatRendering.diffCharacterLimit
                                lineLimit = AcpChatRendering.diffLineLimit
                            }
                            .font(.caption2)
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(.quaternary, lineWidth: KaisolaVisualSystem.hairline))
    }

    private var unifiedBody: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    if isContext(row), let old = row.old {
                        line(prefix: "  ", segments: old, side: .context)
                    } else {
                        if let old = row.old {
                            line(prefix: "- ", segments: old, side: .removed)
                        }
                        if let new = row.new {
                            line(prefix: "+ ", segments: new, side: .added)
                        }
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollClipDisabled()
    }

    private var splitBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 0) {
                    cell(row.old, side: isContext(row) ? .context : .removed)
                    Divider()
                    cell(row.new, side: isContext(row) ? .context : .added)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private enum Side { case context, removed, added }

    private func isContext(_ row: AcpDiff.Row) -> Bool {
        row.old != nil && row.old == row.new
    }

    private func line(prefix: String, segments: [AcpDiff.Segment], side: Side) -> some View {
        Text(attributed(prefix: prefix, segments: segments, side: side))
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background(lineTint(side))
    }

    @ViewBuilder
    private func cell(_ segments: [AcpDiff.Segment]?, side: Side) -> some View {
        Group {
            if let segments {
                Text(attributed(prefix: "", segments: segments, side: side))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .background(lineTint(side))
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 16)
                    .background(.quaternary.opacity(0.15))
            }
        }
    }

    /// Changed words get a deeper tint layered over the line background.
    private func attributed(prefix: String, segments: [AcpDiff.Segment], side: Side) -> AttributedString {
        var result = AttributedString(prefix)
        for segment in segments {
            var piece = AttributedString(segment.text)
            if segment.changed, side != .context {
                piece.backgroundColor = side == .removed
                    ? Color.red.opacity(0.32)
                    : Color.green.opacity(0.32)
            }
            result += piece
        }
        return result
    }

    private func lineTint(_ side: Side) -> Color {
        switch side {
        case .context: .clear
        case .removed: .red.opacity(0.14)
        case .added: .green.opacity(0.14)
        }
    }
}

struct PlanCard: View {
    let entries: [AcpPlanEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Plan", systemImage: "checklist").font(.caption.weight(.semibold))
            ForEach(entries) { entry in
                HStack(spacing: 7) {
                    Image(systemName: entry.status == "completed" ? "checkmark.square" : "square")
                        .foregroundStyle(
                            entry.status == "completed"
                                ? KaisolaStatusTone.done.foregroundColor
                                : Color.kaisolaSecondary
                        )
                    Text(entry.content).strikethrough(entry.status == "completed")
                    Spacer()
                }
                .font(.callout)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AcpPermissionBar: View {
    let review: AcpPermissionReview
    let allowsRule: Bool
    let pendingCount: Int
    let deny: () -> Void
    let allowOnce: () -> Void
    let createRule: () -> Void
    var enablesKeyboardShortcuts = true

    /// The exact payload stays one click away rather than in front of the
    /// decision. Collapsed by default; the summary above already carries the
    /// fields a reviewer needs.
    @State private var showsRawPayload = false

    private var summary: AcpPermissionSummary { review.summary }

    private var ruleUnavailableReason: String {
        review.allowOnceOptionID == nil
            ? "The adapter did not offer an exact one-time allow, so Kaisola cannot create a safe local rule."
            : "This request touches a protected path. Kaisola will always ask."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: allowsRule ? "hand.raised.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(
                        allowsRule
                            ? KaisolaStatusTone.needsYou.foregroundColor
                            : KaisolaStatusTone.failed.foregroundColor
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permission required")
                        .font(.headline)
                    Text(review.title)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if pendingCount > 1 {
                    Text("\(pendingCount - 1) more permission request\(pendingCount == 2 ? "" : "s") queued")
                        .font(.caption2)
                        .foregroundStyle(.kaisolaSecondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            // One vertical scroll for the whole reading, capped so a long ask
            // can never push the decision buttons or the composer off-screen.
            // `fixedSize` keeps a short card short instead of padding it to the
            // cap; nothing inside scrolls, so there is no nested-scroll trap.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    summarySection

                    pathsSection

                    inspectorSection(allowsRule ? "Proposed standing rule" : "Standing rule unavailable") {
                        if allowsRule {
                            ruleScopeRow("Workspace", review.ruleScope.workspace)
                            ruleScopeRow("Action", review.ruleScope.action)
                            ruleScopeRow("Resource", review.ruleScope.resource)
                            Text("Future requests must match all three fields.")
                                .font(.caption2)
                                .foregroundStyle(.kaisolaSecondary)
                        } else {
                            Text(ruleUnavailableReason)
                                .font(.caption)
                                .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !review.omittedOptions.isEmpty {
                        let labels = review.omittedOptions.map { "\($0.name) [\($0.kind)]" }.joined(separator: ", ")
                        Text("Additional adapter choices not exposed: \(labels). Kaisola offers only scoped local persistence and one-time wire decisions.")
                            .font(.caption2)
                            .foregroundStyle(.kaisolaSecondary)
                            .textSelection(.enabled)
                            // Same wrapping rule as the summary: this sentence
                            // names options the user is not being offered, so
                            // it cannot end in an ellipsis.
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    rawPayloadInspector
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                denyButton
                allowOnceButton
                Button("Create Rule") { createRule() }
                    .buttonStyle(.bordered)
                    .tint(.green)
                    .disabled(!allowsRule)
                    .help(allowsRule
                        ? "Allow once and save exactly the workspace, action, and resource shown above"
                        : ruleUnavailableReason)
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(KaisolaStatusTone.needsYou.foregroundColor.opacity(0.35))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission request: \(review.title)")
        .accessibilityHint(review.allowOnceOptionID == nil
            ? "Use Escape to deny this request"
            : "Use Return to allow once or Escape to deny")
    }

    /// The decision, in words, at the top of the card. Every row wraps, so a
    /// narrow chat pane shows the whole command instead of a sideways fragment.
    private var summarySection: some View {
        inspectorSection("What this request does") {
            Text(summary.headline)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !summary.concerns.isEmpty || !summary.escapingPaths.isEmpty {
                alertRow(concernHeadline)
            }

            ForEach(summary.fields) { field in
                summaryRow(field)
            }

            Text(summary.undeclaredLabels.isEmpty
                ? AcpPermissionSummary.unflaggedIsNotSafeNote
                : "The adapter did not declare: \(summary.undeclaredLabels.joined(separator: ", ")). \(AcpPermissionSummary.unflaggedIsNotSafeNote)")
                .font(.caption2)
                .foregroundStyle(.kaisolaSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var concernHeadline: String {
        let escaping = summary.escapingPaths.count
        var parts = summary.concerns
        if escaping > 0 {
            parts.append("\(escaping) path\(escaping == 1 ? "" : "s") outside the workspace.")
        }
        return parts.joined(separator: " ")
    }

    private func summaryRow(_ field: AcpPermissionSummary.Field) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.label)
                .font(.caption2)
                .foregroundStyle(.kaisolaSecondary)
            Text(field.text)
                .font(field.isDeclared ? .caption.monospaced() : .caption)
                .foregroundStyle(field.isDeclared ? Color.primary : Color.kaisolaSecondary)
                .textSelection(.enabled)
                // Wrapping, never sideways scrolling: a multiline command and a
                // long Unicode path both stay readable at any pane width.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let concern = field.concern {
                alertRow(concern)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One element per field keeps VoiceOver reading label, value, then
        // warning, in the order the card lays them out.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            field.concern.map { "\(field.label): \(field.text). Warning: \($0)" }
                ?? "\(field.label): \(field.text)"
        )
    }

    private func alertRow(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Warning: \(text)")
    }

    private var pathsSection: some View {
        inspectorSection("Affected paths (\(summary.paths.count))") {
            if summary.paths.isEmpty {
                Text("None declared by the adapter. That is not a promise the request touches no files.")
                    .font(.caption)
                    .foregroundStyle(.kaisolaSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Every path in full. A clipped or half-cut path is exactly the
                // misreading this card exists to prevent, so the list has no
                // height of its own; the card's single scroll bounds it.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(summary.paths.enumerated()), id: \.offset) { _, entry in
                        pathRow(entry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .inspectorSurface()
            }
        }
    }

    private func pathRow(_ entry: AcpPermissionSummary.PathEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if entry.leavesWorkspace {
                Image(systemName: "arrow.up.forward.square.fill")
                    .font(.caption2)
                    .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
                    .accessibilityHidden(true)
            }
            Text(entry.path)
                .font(.caption.monospaced())
                .foregroundStyle(entry.leavesWorkspace ? KaisolaStatusTone.failed.foregroundColor : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.leavesWorkspace ? "\(entry.path), outside the workspace" : entry.path)
    }

    /// The payload, byte for byte, still selectable — just no longer the first
    /// thing a time-pressed reviewer has to decode.
    private var rawPayloadInspector: some View {
        DisclosureGroup(isExpanded: $showsRawPayload) {
            VStack(alignment: .leading, spacing: 5) {
                Text(review.rawInput)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .inspectorSurface()
                if review.rawInputIsTitleFallback {
                    Text("This adapter did not provide ACP rawInput; the exact title above is the only request payload available.")
                        .font(.caption2)
                        .foregroundStyle(.kaisolaSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 5)
        } label: {
            Text(review.rawInputIsTitleFallback
                ? "Exact agent-provided request"
                : "Exact raw input (unmodified JSON)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.kaisolaSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var denyButton: some View {
        if enablesKeyboardShortcuts {
            baseDenyButton
                .keyboardShortcut(.cancelAction)
        } else {
            baseDenyButton
        }
    }

    private var baseDenyButton: some View {
        Button("Deny") { deny() }
            .buttonStyle(.bordered)
            .tint(.red)
            .accessibilityHint("Deny this request without creating a persistent rule")
    }

    @ViewBuilder
    private var allowOnceButton: some View {
        if enablesKeyboardShortcuts {
            baseAllowOnceButton
                .keyboardShortcut(.defaultAction)
        } else {
            baseAllowOnceButton
        }
    }

    private var baseAllowOnceButton: some View {
        Button("Allow Once") { allowOnce() }
            .buttonStyle(.bordered)
            .disabled(review.allowOnceOptionID == nil)
            .help(review.allowOnceOptionID == nil
                ? "The adapter did not offer a one-time allow option"
                : "Allow only this request without saving a rule")
            .accessibilityHint("Allow this request once without saving a rule")
    }

    @ViewBuilder
    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.kaisolaSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ruleScopeRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.kaisolaSecondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum AcpTranscriptRecoveryExport {
    struct Document: Codable, Equatable, Sendable {
        var formatVersion: Int
        var title: String
        var startOrdinal: Int64
        var isCompleteTranscript: Bool
        var rows: [AcpTranscriptRow]

        init(title: String, startOrdinal: Int64, rows: [AcpTranscriptRow]) {
            let boundedStartOrdinal = max(0, startOrdinal)
            self.formatVersion = 1
            self.title = title
            self.startOrdinal = boundedStartOrdinal
            self.isCompleteTranscript = boundedStartOrdinal == 0
            self.rows = rows
        }
    }

    static func data(title: String, startOrdinal: Int64, rows: [AcpTranscriptRow]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Document(
            title: title,
            startOrdinal: startOrdinal,
            rows: rows
        ))
    }

    static func suggestedFileName(for title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let stem = title.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let compact = String(stem)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return "\(compact.isEmpty ? "chat" : compact)-transcript-recovery.json"
    }
}

private extension View {
    func inspectorSurface() -> some View {
        padding(7)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
    }
}

extension NSImage {
    /// PNG-encode this image, used to normalize a pasteboard or dropped image
    /// before it rides as an ACP image block. Shared with the composer's
    /// Cmd+V interceptor.
    func pngRepresentation() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// The conversation's one overflow: zoom, checkpoints, accounting, export —
/// everything the retired second header strip used to spread across four
/// controls, behind a single quiet ellipsis (2026-08-26 minimalist pass).
///
/// Embedded chats render this inside the containing pane's 32pt header, so a
/// chat surface has exactly one bar; the standalone presentation keeps it at
/// the trailing end of its own single header. Context is reported as tokens
/// used, deliberately without the "/ 1,000k" denominator: the limit read as a
/// wall you were about to hit, and the number that matters is what the session
/// has actually spent.
struct AcpChatOverflowMenu: View {
    @ObservedObject var conversation: AcpConversation
    @ObservedObject private var previewSettings = NativePreviewSettings.shared

    @State private var restoreTarget: AcpConversation.TurnCheckpoint?
    @State private var isExportingTranscript = false

    var body: some View {
        Menu {
            Menu("Chat Zoom") {
                ForEach(AgentChatTextSize.allCases) { size in
                    Button {
                        previewSettings.agentChatTextSize = size
                    } label: {
                        if previewSettings.agentChatTextSize == size {
                            Label(size.title, systemImage: "checkmark")
                        } else {
                            Text(size.title)
                        }
                    }
                }
            }
            if !conversation.checkpoints.isEmpty {
                Menu("Restore Checkpoint") {
                    Text("Restore the working tree to before a turn:")
                    ForEach(conversation.checkpoints.reversed()) { checkpoint in
                        let time = checkpoint.at.formatted(date: .omitted, time: .shortened)
                        Button("Turn \(checkpoint.turn) — \(time)") {
                            restoreTarget = checkpoint
                        }
                        .accessibilityLabel(CheckpointMenuAccessibility.choiceLabel(
                            turn: checkpoint.turn,
                            time: time
                        ))
                        .accessibilityHint(CheckpointMenuAccessibility.choiceHint)
                    }
                }
                .accessibilityIdentifier(CheckpointMenuAccessibility.identifier)
            }
            Divider()
            Button("Copy Last Response") { copyLastResponse() }
                .disabled(conversation.lastAssistantResponse == nil)
            Button("Export/Open as Markdown…") { exportAndOpenMarkdown() }
                .disabled(
                    isExportingTranscript
                        || (conversation.rows.isEmpty && conversation.hiddenEarlierCount == 0)
                )
            if let usage = conversation.usage {
                Divider()
                // Non-interactive accounting rows: what the session has spent,
                // available on demand instead of ambient in a bar.
                Text("Context used: \(usage.used / 1000)k")
                if let amount = usage.costAmount,
                   let cost = UsageCenter.costLabel(amount: amount, currency: usage.costCurrency) {
                    Text("Session cost: \(cost)")
                }
            }
        } label: {
            // The 24×22 slot lives on the LABEL, inside the menu's own
            // `.fixedSize()`: on the outside it only centered an
            // intrinsically-sized glyph, so this control's real click target
            // was the bare 16pt symbol while every sibling in the header
            // answered across its whole slot.
            Group {
                if isExportingTranscript {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .frame(width: 24, height: 22)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Chat options")
        .accessibilityLabel("Chat options")
        .accessibilityIdentifier("acp.chatOverflowMenu")
        .confirmationDialog(
            "Restore checkpoint?",
            isPresented: Binding(get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } })
        ) {
            Button("Restore Files", role: .destructive) {
                if let restoreTarget { conversation.restoreCheckpoint(restoreTarget) }
                restoreTarget = nil
            }
            Button("Cancel", role: .cancel) { restoreTarget = nil }
        } message: {
            Text("Applies the snapshot taken before turn \(restoreTarget?.turn ?? 0) over the current working tree. Conflicts surface as git conflict markers.")
        }
    }

    @MainActor
    private func copyLastResponse() {
        guard let response = conversation.lastAssistantResponse else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(response, forType: .string) else {
            ToastCenter.shared.show("Could not copy the last response.", style: .error)
            return
        }
        ToastCenter.shared.show("Last response copied.", style: .success)
    }

    @MainActor
    private func exportAndOpenMarkdown() {
        let panel = NSSavePanel()
        panel.title = "Export and Open Chat as Markdown"
        panel.prompt = "Export & Open"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = AcpTranscriptMarkdownExport.suggestedFileName(
            for: conversation.title
        )
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isExportingTranscript = true
        Task { @MainActor in
            defer { isExportingTranscript = false }
            do {
                _ = try await conversation.exportTranscriptMarkdown(to: destination)
                guard NSWorkspace.shared.open(destination) else {
                    throw CocoaError(.fileNoSuchFile)
                }
            } catch {
                ToastCenter.shared.show(
                    "Could not export the chat as Markdown: \(error.localizedDescription)",
                    style: .error
                )
            }
        }
    }
}
