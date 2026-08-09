import SwiftUI

/// The Mesh surface: one composer fanning a prompt to every agent column;
/// side-by-side streaming transcripts; per-column status, inline permission
/// answers, and a worktree diff sheet for judging each agent's edits.
struct MeshView: View {
    enum Presentation: Sendable, Equatable {
        case standard
        case embedded
    }

    @ObservedObject var mesh: MeshSession
    private let presentation: Presentation
    @State private var diffColumnID: String?
    @State private var diffText = ""
    @State private var integrateColumnID: String?
    @State private var integrationOutcome: MeshIntegrationOutcome?
    /// The column the reported outcome belongs to, so "Try Again" and "Review
    /// Diff" act on it rather than guessing from the message.
    @State private var integratedColumnID: String?
    @FocusState private var composerFocused: Bool
    private let focusRequestGeneration: UInt64?
    private let onKeyboardFocus: (() -> Void)?

    init(
        mesh: MeshSession,
        presentation: Presentation = .standard,
        focusRequestGeneration: UInt64? = nil,
        onKeyboardFocus: (() -> Void)? = nil
    ) {
        _mesh = ObservedObject(wrappedValue: mesh)
        self.presentation = presentation
        self.focusRequestGeneration = focusRequestGeneration
        self.onKeyboardFocus = onKeyboardFocus
    }

    var body: some View {
        VStack(spacing: 0) {
            if presentation == .standard {
                header
                Divider()
            }
            if let outcome = integrationOutcome {
                integrationStatusBar(outcome)
                Divider()
            }
            if mesh.columns.isEmpty {
                if mesh.lifecycle == .recoveryRequired {
                    ContentUnavailableView {
                        Label("Mesh recovery needed", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text("Kaisola preserved this run's Git manifest but could not safely reattach every worktree. Nothing was deleted.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("Starting agents…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(mesh.columns.enumerated()), id: \.element.id) { index, column in
                        if index > 0 { Divider() }
                        MeshColumnView(
                            column: column,
                            enablesPermissionShortcuts: column.id == firstPermissionColumnID,
                            stop: { Task { await mesh.stopTurn(columnID: column.id) } },
                            showDiff: { diffColumnID = column.id },
                            integrate: { integrateColumnID = column.id }
                        )
                    }
                }
            }
            Divider()
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .confirmationDialog(
            "Apply this column's diff to the base project?",
            isPresented: Binding(
                get: { integrateColumnID != nil },
                set: { if !$0 { integrateColumnID = nil } }
            ),
            presenting: integrateColumnID
        ) { columnID in
            Button("Apply Diff") { integrate(columnID) }
            Button("Cancel", role: .cancel) { integrateColumnID = nil }
        } message: { _ in
            Text("Grafts this column's edits onto \(mesh.baseDirectory.lastPathComponent) with a 3-way merge. Conflicts leave git markers you'll need to resolve.")
        }
        .sheet(item: Binding(
            get: { diffColumnID.map(DiffSheetID.init) },
            set: { diffColumnID = $0?.id }
        )) { sheet in
            VStack(spacing: 0) {
                HStack {
                    Text("Worktree diff — \(mesh.columns.first { $0.id == sheet.id }?.agent.name ?? "")")
                        .font(.headline)
                    Spacer()
                    Button("Done") { diffColumnID = nil }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
                Divider()
                ScrollView {
                    UnifiedPatchView(patch: diffText.isEmpty ? "No changes yet." : diffText)
                        .padding(12)
                }
            }
            .frame(width: 640, height: 480)
            .task { diffText = await mesh.diff(for: sheet.id) }
        }
        .onAppear { applyFocusRequest(focusRequestGeneration) }
        .onChange(of: focusRequestGeneration) { _, request in
            applyFocusRequest(request)
        }
    }

    private struct DiffSheetID: Identifiable {
        let id: String
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.hexagongrid.fill").foregroundStyle(.purple)
            Text(mesh.title).font(.subheadline.weight(.medium))
            if let chip = headerChip {
                Text(chip)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.purple.opacity(0.15)))
            }
            if mesh.anyRunning {
                ProgressView().controlSize(.small)
            }
            if let note = mesh.isolationNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(KaisolaStatusTone.needsYou.foregroundColor)
            }
            Spacer()
            MeshStagedPromptQueueButton(mesh: mesh)
            if mesh.anyRunning {
                Button {
                    Task { await mesh.stopAllTurns() }
                } label: {
                    Label("Stop All", systemImage: "stop.circle")
                }
                .buttonStyle(.borderless)
                .help("Stop every running Mesh column without deleting the run")
            }
            configurationMenu
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(.ultraThinMaterial)
    }

    private var configurationMenu: some View {
        MeshConfigurationMenu(mesh: mesh)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Send to every agent…", text: $mesh.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .focused($composerFocused)
                .onChange(of: composerFocused) { _, focused in
                    if focused { onKeyboardFocus?() }
                }
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(mesh.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Fan this prompt out to every column")
        }
        .padding(10)
        .background(.ultraThinMaterial)
    }

    private func applyFocusRequest(_ generation: UInt64?) {
        guard generation != nil else { return }
        DispatchQueue.main.async {
            composerFocused = true
        }
    }

    private func send() {
        let text = mesh.draft
        let accepted: Bool
        switch (mesh.purpose, mesh.mode) {
        case (.idea, _): accepted = mesh.sendIdea(text)
        case (.build, .staged): accepted = mesh.sendStaged(text)
        case (.build, .flat): accepted = mesh.send(text)
        }
        if accepted {
            mesh.draft = ""
        }
    }

    /// The header status chip: the run's purpose plus, when a staged/idea
    /// pipeline is active, its current phase. Nil for a plain flat build run.
    private var headerChip: String? {
        let queued = mesh.stagedQueuedPromptCount > 0
            ? " · \(mesh.stagedQueuedPromptCount) queued"
            : ""
        switch mesh.purpose {
        case .idea:
            return mesh.stage == "Idle" ? "Idea" : "Idea · \(mesh.stage)"
        case .build:
            return mesh.mode == .staged ? "Staged · \(mesh.stage)\(queued)" : nil
        }
    }

    private var firstPermissionColumnID: String? {
        mesh.columns.first { $0.conversation.pendingPermission != nil }?.id
    }

    /// The integration status line. Tint, symbol, what VoiceOver says, and which
    /// buttons appear all come from the typed outcome, so a permission,
    /// repository, patch, or I/O failure stays as loud as a conflict no matter
    /// how git worded it.
    private func integrationStatusBar(_ outcome: MeshIntegrationOutcome) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(outcome.message, systemImage: outcome.symbol)
                .font(.caption)
                .foregroundStyle(outcome.severity.foregroundColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(outcome.accessibilityAnnouncement)
            ForEach(outcome.recoveryActions) { action in
                Button(action.title) { perform(action) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(action.help)
                    .accessibilityLabel("\(action.title): \(action.help)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }

    /// Run one of the outcome's offered recoveries against the column it came
    /// from.
    private func perform(_ action: MeshIntegrationOutcome.Recovery) {
        switch action {
        case .reviewDiff:
            diffColumnID = integratedColumnID
        case .retry:
            if let columnID = integratedColumnID { integrate(columnID) }
        case .revealDestination:
            NSWorkspace.shared.activateFileViewerSelecting([mesh.baseDirectory])
        case .dismiss:
            integrationOutcome = nil
            integratedColumnID = nil
        }
    }

    /// Graft the column's worktree diff onto the base workspace and keep the
    /// typed outcome it reports. Runs on the main actor so the @State writes are
    /// safe.
    private func integrate(_ columnID: String) {
        integratedColumnID = columnID
        Task { @MainActor in
            integrationOutcome = await mesh.integrate(columnID: columnID)
        }
    }
}

private extension MeshIntegrationOutcome.Severity {
    /// The only place a severity becomes a colour. Each state also carries its
    /// own symbol, so tint is reinforcement rather than the whole signal.
    var foregroundColor: Color {
        switch self {
        case .success: KaisolaStatusTone.done.foregroundColor
        case .informational: Color.secondary
        case .warning: KaisolaStatusTone.needsYou.foregroundColor
        case .failure: KaisolaStatusTone.failed.foregroundColor
        }
    }
}

/// Shared by standalone and embedded Mesh headers so a restored queue is never
/// hidden behind a particular presentation mode.
struct MeshStagedPromptQueueButton: View {
    @ObservedObject var mesh: MeshSession
    @State private var isPresented = false

    var body: some View {
        if !mesh.stagedPrompts.isEmpty {
            Button {
                isPresented.toggle()
            } label: {
                Label("\(mesh.stagedPrompts.count)", systemImage: "tray.full")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .help("Review queued Mesh prompts")
            .accessibilityLabel(queueAccessibilityLabel)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                queueInspector
            }
        }
    }

    private var queueAccessibilityLabel: String {
        let count = mesh.stagedPrompts.count
        return "Review \(count) queued \(count == 1 ? "prompt" : "prompts")"
    }

    private var queueInspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Queued Prompts")
                        .font(.headline)
                    Text("Waiting in dispatch order")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    _ = mesh.resumeStagedQueue()
                } label: {
                    Label("Resume Queue", systemImage: "play.fill")
                }
                .disabled(!mesh.canResumeStagedQueue)
                .help("Dispatch the oldest waiting prompt")
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(mesh.stagedPrompts.enumerated()), id: \.offset) { index, prompt in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("Prompt \(index + 1)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(role: .destructive) {
                                    if mesh.removeStagedPrompt(prompt, at: index), mesh.stagedPrompts.isEmpty {
                                        isPresented = false
                                    }
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                        .labelStyle(.titleAndIcon)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove queued prompt \(index + 1)")
                            }
                            Text(prompt)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(
                            Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Queued prompt \(index + 1)")
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 390, height: 360)
    }
}

/// Compact configuration accessory shared by the standalone Mesh header and
/// the unified session-card header. Session identity and activity therefore
/// appear once while current ACP/MCP configuration remains one click away.
struct MeshConfigurationMenu: View {
    @ObservedObject var mesh: MeshSession

    var body: some View {
        Menu {
            Section("Project") {
                Label(mesh.baseDirectory.path, systemImage: "folder")
            }
            Section("ACP adapters") {
                if mesh.configuredAgentNames.isEmpty {
                    Text("No compatible adapters")
                } else {
                    ForEach(mesh.configuredAgentNames, id: \.self) { name in
                        Label(name, systemImage: "checkmark.circle")
                    }
                }
            }
            Section("MCP servers") {
                if mesh.configuredMCPServerNames.isEmpty {
                    Text("No enabled servers")
                } else {
                    ForEach(mesh.configuredMCPServerNames, id: \.self) { name in
                        Label(name, systemImage: "server.rack")
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                Text("\(mesh.configuredAgentNames.count) ACP · \(mesh.configuredMCPServerNames.count) MCP")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .kaisolaControlSurface(active: true, tint: .purple)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Current project ACP and MCP configuration")
    }
}

/// One agent's column: status, streaming transcript, inline permission answers,
/// and the worktree diff affordance.
private struct MeshColumnView: View {
    let column: MeshSession.Column
    let enablesPermissionShortcuts: Bool
    let stop: () -> Void
    let showDiff: () -> Void
    let integrate: () -> Void
    @ObservedObject private var conversation: AcpConversation
    @State private var transcriptIsReady = false
    @State private var loadingEarlierRows = false
    @State private var transcriptIsAtBottom = true
    @State private var hasUnseenTranscriptUpdates = false

    init(
        column: MeshSession.Column,
        enablesPermissionShortcuts: Bool,
        stop: @escaping () -> Void,
        showDiff: @escaping () -> Void,
        integrate: @escaping () -> Void
    ) {
        self.column = column
        self.enablesPermissionShortcuts = enablesPermissionShortcuts
        self.stop = stop
        self.showDiff = showDiff
        self.integrate = integrate
        self.conversation = column.conversation
    }

    /// A dotted ring, a filled disc, and a hollow ring — three shapes, so the
    /// tint below is reinforcement rather than the only way to read the state.
    private var statusSymbol: String {
        if conversation.isRunning { return "circle.dotted" }
        return conversation.isConnected ? "circle.fill" : "circle"
    }

    private var statusTint: Color {
        if conversation.isRunning { return .accentColor }
        return conversation.isConnected ? .green : .secondary
    }

    private var statusDescription: String {
        if conversation.isRunning { return "Working" }
        return conversation.isConnected ? "Connected" : "Not connected"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: column.agent.symbol).foregroundStyle(.purple)
                Text(column.agent.name).font(.callout.weight(.semibold))
                // Three states off one tinted dot meant colour was the whole
                // signal. Each state now has its own outline as well, and says
                // its name to VoiceOver and on hover.
                Image(systemName: statusSymbol)
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(statusTint)
                    .accessibilityElement()
                    .accessibilityLabel("\(column.agent.name): \(statusDescription)")
                    .help(statusDescription)
                Spacer()
                if conversation.isRunning {
                    Button(action: stop) {
                        Image(systemName: "stop.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop \(column.agent.name) without deleting its transcript")
                    .accessibilityLabel("Stop \(column.agent.name) turn")
                }
                if column.worktreePath != nil {
                    Button("Diff", action: showDiff)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("This column's isolated worktree diff vs HEAD")
                    Button("Integrate", action: integrate)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Apply this column's diff onto the base project")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.thinMaterial)
            Divider()
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if conversation.hiddenEarlierCount > 0 {
                                HStack(spacing: 6) {
                                    if loadingEarlierRows { ProgressView().controlSize(.mini) }
                                    Text(loadingEarlierRows ? "Loading earlier messages…" : "Earlier messages")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .onAppear {
                                    guard transcriptIsReady,
                                          !loadingEarlierRows,
                                          let anchor = conversation.visibleRows.first?.id else { return }
                                    loadingEarlierRows = true
                                    Task { @MainActor in
                                        await conversation.expandEarlier()
                                        TerminalTranscriptScrollPolicy.preserveUserVelocity {
                                            proxy.scrollTo(anchor, anchor: .top)
                                        }
                                        loadingEarlierRows = false
                                    }
                                }
                            } else if transcriptIsReady, !conversation.rows.isEmpty {
                                Text("Beginning of session")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                            }
                            if let status = conversation.statusMessage {
                                Label(status, systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.secondary)
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
                                .id("mesh-transcript-bottom-\(column.id)")
                                .onAppear {
                                    transcriptIsAtBottom = true
                                    hasUnseenTranscriptUpdates = false
                                }
                                .onDisappear { transcriptIsAtBottom = false }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if transcriptIsReady, !transcriptIsAtBottom, !conversation.rows.isEmpty {
                        Button {
                            hasUnseenTranscriptUpdates = false
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("mesh-transcript-bottom-\(column.id)", anchor: .bottom)
                            }
                        } label: {
                            Image(systemName: hasUnseenTranscriptUpdates ? "arrow.down.circle.fill" : "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(8)
                        .help(hasUnseenTranscriptUpdates ? "Jump to new output" : "Jump to latest")
                        .accessibilityLabel(hasUnseenTranscriptUpdates ? "Jump to new agent output" : "Jump to latest agent output")
                    }
                }
                .onAppear {
                    transcriptIsReady = false
                    transcriptIsAtBottom = true
                    hasUnseenTranscriptUpdates = false
                    DispatchQueue.main.async {
                        proxy.scrollTo("mesh-transcript-bottom-\(column.id)", anchor: .bottom)
                        transcriptIsReady = true
                    }
                }
                .onChange(of: conversation.contentVersion) { _, newVersion in
                    guard transcriptIsReady,
                          conversation.lastHistoryInsertionContentVersion != newVersion else { return }
                    if transcriptIsAtBottom {
                        DispatchQueue.main.async {
                            proxy.scrollTo("mesh-transcript-bottom-\(column.id)", anchor: .bottom)
                        }
                    } else {
                        hasUnseenTranscriptUpdates = true
                    }
                }
            }
            if let review = conversation.pendingPermissionReview {
                Divider()
                AcpPermissionBar(
                    review: review,
                    allowsRule: conversation.pendingPermissionAllowsRule,
                    pendingCount: conversation.pendingPermissionCount,
                    deny: { conversation.denyPermission() },
                    allowOnce: { conversation.allowPermissionOnce() },
                    createRule: { conversation.answerPermissionAlways() },
                    enablesKeyboardShortcuts: enablesPermissionShortcuts
                )
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .task { await conversation.start() }
    }
}

/// A raw unified diff with the standard +/− tinting (shared Mesh/diff-sheet
/// rendering).
struct UnifiedPatchView: View {
    let patch: String

    private var rendered: GitBoundedPatch { GitPatchRendering.bounded(patch) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rendered.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 3)
                    .background(tint(for: line))
            }
            if rendered.isTruncated {
                Label("Large diff truncated in this view", systemImage: "ellipsis.rectangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
    }

    private func tint(for line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return .green.opacity(0.13) }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return .red.opacity(0.13) }
        if line.hasPrefix("@@") { return .accentColor.opacity(0.13) }
        return .clear
    }
}
