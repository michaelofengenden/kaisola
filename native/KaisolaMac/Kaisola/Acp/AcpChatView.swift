import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    @State private var restoreTarget: AcpConversation.TurnCheckpoint?
    @ObservedObject var conversation: AcpConversation
    private let presentation: Presentation
    @State private var draft = ""
    /// Highlights the composer while an OS file drag hovers it.
    @State private var isDropTargeted = false
    @State private var transcriptIsReady = false
    @State private var loadingEarlierRows = false
    @State private var transcriptIsAtBottom = true
    @State private var hasUnseenTranscriptUpdates = false
    @State private var transcriptConversationID: ObjectIdentifier?
    @FocusState private var composerFocused: Bool
    private let focusRequestGeneration: UInt64?
    private let onKeyboardFocus: (() -> Void)?

    init(
        conversation: AcpConversation,
        presentation: Presentation = .standard,
        focusRequestGeneration: UInt64? = nil,
        onKeyboardFocus: (() -> Void)? = nil
    ) {
        _conversation = ObservedObject(wrappedValue: conversation)
        self.presentation = presentation
        self.focusRequestGeneration = focusRequestGeneration
        self.onKeyboardFocus = onKeyboardFocus
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
            if presentation == .standard {
                standardHeader
            } else {
                embeddedControls
            }
            Divider()
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
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: KaisolaVisualSystem.panelRadius)
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
            draft = conversation.loadDraft()
            await conversation.start()
        }
        .onChange(of: draft) { _, newValue in
            conversation.saveDraft(newValue)
        }
        .onAppear { applyFocusRequest(focusRequestGeneration) }
        .onChange(of: focusRequestGeneration) { _, request in
            applyFocusRequest(request)
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
            if conversation.isRunning {
                ProgressView().controlSize(.small)
                Text("Working…").font(.caption).foregroundStyle(.kaisolaSecondary)
            }
            Spacer()
            sessionControls
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    /// The containing session card supplies title, connection, and activity.
    /// Keeping this row a fixed, quiet height prevents asynchronously-arriving
    /// model/config metadata from pushing the transcript during startup.
    private var embeddedControls: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            sessionControls
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    /// What stays in the header now that the composer owns the agent controls.
    ///
    /// Model, permission mode, and adapter options moved onto the composer's
    /// chip rail, where the reference apps put them and where they sit next to
    /// the message they will govern. Duplicating them up here would have left
    /// two controls for one setting; what remains is session *history* and
    /// *accounting*, which belong to the whole conversation rather than the
    /// next turn.
    @ViewBuilder
    private var sessionControls: some View {
        if !conversation.checkpoints.isEmpty {
            Menu {
                Text("Restore the working tree to before a turn:")
                ForEach(conversation.checkpoints.reversed()) { checkpoint in
                    Button("Turn \(checkpoint.turn) — \(checkpoint.at.formatted(date: .omitted, time: .shortened))") {
                        restoreTarget = checkpoint
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Pre-turn checkpoints (git snapshots)")
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
        if let usage = conversation.usage {
            Text("\(usage.used / 1000)k / \(usage.max / 1000)k")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.kaisolaSecondary)
            if let amount = usage.costAmount,
               let cost = UsageCenter.costLabel(amount: amount, currency: usage.costCurrency) {
                Text(cost)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.kaisolaSecondary)
                    .help("Cumulative cost reported by this agent session")
                    .accessibilityLabel("Session cost \(cost)")
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if conversation.hiddenEarlierCount > 0 {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(loadingEarlierRows ? "Loading earlier messages…" : "Earlier messages")
                                    .font(.caption)
                                    .foregroundStyle(.kaisolaSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .onAppear {
                                guard transcriptIsReady,
                                      transcriptConversationID == ObjectIdentifier(conversation),
                                      !loadingEarlierRows,
                                      let anchor = conversation.visibleRows.first?.id else { return }
                                loadingEarlierRows = true
                                Task { @MainActor in
                                    await conversation.expandEarlier()
                                    guard transcriptConversationID == ObjectIdentifier(conversation) else {
                                        loadingEarlierRows = false
                                        return
                                    }
                                    // Expanding prepends rows. Restore the formerly
                                    // first visible row so the viewport does not jump,
                                    // while retaining active trackpad velocity on
                                    // macOS 15 and newer.
                                    TerminalTranscriptScrollPolicy.preserveUserVelocity {
                                        proxy.scrollTo(anchor, anchor: .top)
                                    }
                                    loadingEarlierRows = false
                                }
                            }
                        } else if transcriptIsReady, !conversation.rows.isEmpty {
                            Label("Beginning of session", systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.kaisolaSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .accessibilityLabel("Beginning of session history")
                        }
                        if let status = conversation.statusMessage {
                            Label(status, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.kaisolaSecondary)
                        }
                        ForEach(conversation.visibleRows) { row in
                            TranscriptRowView(
                                row: row,
                                workspaceURL: conversation.workspaceURL,
                                retry: { conversation.retryFailed($0) },
                                terminalSnapshot: { [weak conversation] id in await conversation?.terminalSnapshot(id) }
                            )
                            .id(row.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("acp-transcript-bottom")
                            .onAppear {
                                transcriptIsAtBottom = true
                                hasUnseenTranscriptUpdates = false
                            }
                            .onDisappear { transcriptIsAtBottom = false }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if transcriptIsReady, !transcriptIsAtBottom, !conversation.rows.isEmpty {
                    Button {
                        hasUnseenTranscriptUpdates = false
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
                transcriptIsReady = false
                transcriptIsAtBottom = true
                hasUnseenTranscriptUpdates = false
                DispatchQueue.main.async {
                    proxy.scrollTo("acp-transcript-bottom", anchor: .bottom)
                    transcriptIsReady = true
                }
            }
            .onChange(of: conversation.contentVersion) { _, newVersion in
                guard transcriptIsReady,
                      conversation.lastHistoryInsertionContentVersion != newVersion else { return }
                if transcriptIsAtBottom {
                    DispatchQueue.main.async {
                        if presentation == .standard {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("acp-transcript-bottom", anchor: .bottom)
                            }
                        } else {
                            // A unified card can swap sessions in place. Do not
                            // animate from the preceding session's scroll offset.
                            proxy.scrollTo("acp-transcript-bottom", anchor: .bottom)
                        }
                    }
                } else {
                    hasUnseenTranscriptUpdates = true
                }
            }
        }
        .id(ObjectIdentifier(conversation))
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
            if !conversation.isConnected, conversation.statusMessage != nil {
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
                isNewConversation: showsEmptyState,
                send: sendDraft,
                onKeyboardFocus: onKeyboardFocus
            )
        }
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
                            conversation.removeAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.kaisolaSecondary)
                        .help("Remove this attachment")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
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

    /// Stage files dropped onto the composer.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [conversation] data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in conversation.prepareAttachment(fileURL: url) }
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

struct TranscriptRowView: View {
    let row: AcpTranscriptRow
    var workspaceURL: URL?
    var retry: ((String) -> Void)?
    var terminalSnapshot: (@Sendable (String) async -> AcpTerminalHost.Snapshot?)?

    var body: some View {
        switch row {
        case let .user(_, text, failed):
            HStack(spacing: 8) {
                Spacer(minLength: 40)
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
                Text(text)
                    .padding(10)
                    .background(
                        failed ? Color.red.opacity(0.12) : Color.accentColor.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .overlay {
                        if failed {
                            RoundedRectangle(cornerRadius: 10).strokeBorder(.red.opacity(0.5))
                        }
                    }
                    .textSelection(.enabled)
            }
            // Identified so the user's own side of the transcript — including a
            // prompt restored from a resumed thread, and a message steered into
            // a running turn — is inspectable.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("acp.transcript.\(row.id)")
            .accessibilityLabel("You said: \(text)")
        case let .message(_, text):
            AssistantMarkdownText(text: text, workspaceURL: workspaceURL)
        case let .thought(_, text):
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
        case let .tool(call):
            ToolCallCard(
                call: call,
                workspaceURL: workspaceURL,
                terminalSnapshot: terminalSnapshot
            )
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

struct ToolCallCard: View {
    let call: AcpToolCall
    var workspaceURL: URL?
    var terminalSnapshot: (@Sendable (String) async -> AcpTerminalHost.Snapshot?)?
    @State private var expanded = false

    private var hasArtifacts: Bool { !call.content.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if hasArtifacts { expanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                    Text(call.title).lineLimit(1)
                    Spacer()
                    if hasArtifacts {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.kaisolaSecondary)
                    }
                    Text(call.kind).font(.caption).foregroundStyle(.kaisolaSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasArtifacts)

            if !call.locations.isEmpty {
                Text(AcpTranscriptInlineRendering.attributed(
                    call.locations.joined(separator: ", "),
                    workspaceURL: workspaceURL
                ))
                    .font(.caption).foregroundStyle(.kaisolaSecondary).lineLimit(1)
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
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .environment(\.openURL, OpenURLAction { link in
            AcpTranscriptLinkRouting.open(link, workspaceURL: workspaceURL)
        })
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
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
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
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
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

private extension View {
    func inspectorSurface() -> some View {
        padding(7)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
    }
}

private extension NSImage {
    /// PNG-encode this image, used to normalize a pasteboard image before it
    /// rides as an ACP image block.
    func pngRepresentation() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
